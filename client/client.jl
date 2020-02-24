using Sockets

import Base.Threads.@spawn

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer


struct Server
    host::IPv4
    port::Int
end

# NOTE: might not need this
function timeout(n::Union{Float64, Int64}, v::Bool = false)
    sleep(n)
    v && println("Timed out")
    return false
end


function receive_from(socket::UDPSocket, recv_channels::Dict{Server,Channel{Any}})
    resp = recvfrom(socket)
    server, r = Server(resp[1].host, resp[1].port), resp[2]
    @debug "Got $(length(r)) bytes from $server."
    # if we receive from a server, then put the data in the channel for the corresponding server
    put!(recv_channels[server], r)
    return "receive_from"
end


function handle(
    socket::UDPSocket,
    server::Server,
    file::String,
    numbytes::Int,
    chunks::Channel,
    recv_channels::Dict{Server, Channel{Any}},
    final_image_channel::Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}
    )
    states = [
        "waiting for file",
        "waiting for job",
        "processing job",
        "finished"
    ]
    server_state = states[1]
    confirmcode  = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    maxtries = 5
    done = false
    debug = false

    @debug "Starting handle for $server."
    while !done
        tries = 0
        while server_state == states[1] # waiting for file
            @debug "Server $server: state: $server_state."
            tries += 1
            open(file, "r") do io
                # converts the UInt64 hash to an array of UInt8 partial hashes.
                h = reinterpret(UInt8, [hash(read(io, String))])
                seekstart(io)

                # the server will have to know to connect the first 8 bytes of file-sending messages to form the file hash
                bs = read(io, numbytes)
                while length(bs) > 0
                    # send numbytes-byte packets, adding the file hash (8 bytes) to the beginning of each message
                    @info "Sending file to $server. Bytes remaining: $(length(bs))."
                    send(socket, server.host, server.port, cat(h, bs, dims=1))
                    bs = read(io, numbytes)
                end
            end
            # send(socket, server.host, server.port, confirmcode)
            r = take!(recv_channels[server])
            if r == confirmcode
                @info "Server $server got the whole file, moving to state 2."
                server_state = states[2]
            else
                @error "Server $server did not get the whole file. Retrying ($tries/$maxtries)"
                tries > maxtries && return (false, server)  # just give up talking to this server at this point.
            end
        end

        tries = 0
        chunk = take!(chunks)
        while server_state == states[2]  # waiting for job
            @debug "Server $server: state: $server_state."
            tries += 1

            # I am the voice of one calling in the wilderness...
            send(socket, server.host, server.port, reinterpret(UInt8, [chunk.start, chunk.stop]))
            r = take!(recv_channels[server])
            if r == confirmcode
                @info "Server $server started working on pixels $chunk, moving to state 3."
                server_state = states[3]
            else
                @error "Sending job to $server failed, retrying ($tries/$maxtries)"
                tries > maxtries && (put!(chunks, chunk); return (false, server))  # just give up talking to this server at this point.
                sleep(0.1)  # wait some time to give other tasks a chance to take that chunk.
            end
        end

        tries = 0
        r = UInt8[]
        while server_state == states[3]  # processing job
            @debug "Server $server: state: $server_state."
            tries += 1

            r = take!(recv_channels[server])
            # if the length of what we got is shorter/longer than what we expected, or if recv timed out
            # if we've tried too many times, send chunk back to chunks and return
            if length(r) != (chunk.stop - chunk.start + 1)*3 || r == errorcode
                @error "Server $server sent back a strange result or an error. Expected length: $((chunk.stop - chunk.start + 1)*3) Got: $(length(r))."
                tries > maxtries && (put!(chunks, chunk); return (false, server))
                send(socket, server.host, server.port, errorcode)
            else
                @info "Server $server sent back completed chunk $chunk. Moving to state 4."
                send(socket, server.host, server.port, confirmcode)
                server_state = states[4]
            end
        end

        if server_state == states[4]  # finished
            @debug "Server $server: state: $server_state."
            put!(final_image_channel, (chunk, r))
            server_state = states[2]
            !isready(chunks) && (done = true)
        end
    end
    return ("handle", server)
end


function update_final_image(
    final_image::Array{Union{Missing, UInt8}, 2},
    final_image_channel::Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}
    )
    chunk, result = take!(final_image_channel)
    final_image[chunk, :] = transpose(reshape(result, 3, div(length(result), 3)))
    return "update_final_image"
end


function main()
    if length(ARGS) != 3
        println("Usage: julia $PROGRAM_FILE [scene file] [server file] [ppm file name]")
        return nothing
    end
    server_list = readlines(ARGS[2])
    # push!(server_list, "localhost")
    server_list = map(i -> Server(getaddrinfo(i), 9105), server_list)

    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 8105)
    file = ARGS[1]
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    view, scene = parseFile(file)
    final_image = Array{Union{UInt8, Missing}}(missing, view.height * view.width, 3)
    N = view.height * view.width  # Total number of pixels in image
    num_chunks = ceil(Int, N/numpixels)

    final_image_channel = Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}(num_chunks)
    chunks = Channel{UnitRange{Int64}}(num_chunks)  # Tracks chunks, or individual jobs.
    for chunk in [i+1:i+numpixels for i in 0:numpixels:N]
        if chunk.stop > N
            chunk = chunk.start:N
        end
        put!(chunks, chunk)
    end
    recv_channels = Dict(server => Channel(Inf) for server in server_list)
    println("Initialised chunks, recv_channels, final_image_channel, view, scene.")

    tasks = Array{Any, 1}(undef, length(server_list))
    map!(server ->
        () -> Task(() -> handle(socket, server, file, numbytes, chunks, recv_channels, final_image_channel)),
        tasks,
        server_list
    )
    push!(tasks, () -> Task(() -> receive_from(socket, recv_channels)))
    push!(tasks, () -> Task(() -> update_final_image(final_image, final_image_channel)))
    tasklist = [(:take, schedule(t())) for t in tasks]
    # println("Created task list. Length is $(length(tasklist))")
    while any(ismissing, final_image)  # while image is not completed
        # TODO: update tasklist successfully
        i, r = select(tasklist)  # i is index of server_list, r is return value of first function to return

        if r == "update_final_image"
            number_missing = count(ismissing, final_image)
            percentage_missing = 100.0 - number_missing / length(final_image) * 100
            print("Final image percentage complete: %$(round(percentage_missing, digits=2))\r")
            tasklist[i] = (:take, schedule(Task(() -> update_final_image(final_image, final_image_channel))))
            # continue
        elseif r == "receive_from"
            tasklist[i] = (:take, schedule(Task(() -> receive_from(socket, recv_channels))))
            # continue
        # elseif r[1] == false  # timed out
        #     println("Timed out in main execution with server $(r[2]). All retries should already have been attempted.")
        #     break
        elseif r[1] == "handle"
            flag, server = r
            println("Finished with server $server.")
            # continue
            # tasklist[i] = (:take, schedule(Task(() -> handle(socket, server_list[i], file, numbytes, chunks, recv_channels, final_image_channel))))
        end
    end
    close(socket)
    close(final_image_channel)
    close(chunks)
    final_image = permutedims(reshape(final_image, view.height, view.width, 3), [2, 1, 3])
    writePPM(ARGS[3], final_image)
end

main()