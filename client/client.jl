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


function receive_from(
        recv_socket::UDPSocket,
        recv_channels::Dict{Server,Channel{Any}}
    )
    resp = recvfrom(recv_socket)
    server, r = Server(resp[1].host, resp[1].port), resp[2]
    @debug "Got $(length(r)) bytes from $server."
    # if we receive from a server, then put the data in the channel for the corresponding server
    put!(recv_channels[server], r)
    return "receive_from", server
end


function send_to(
        send_socket::UDPSocket,
        send_channel::Channel{Tuple{Server, Array{UInt8,1}}}
    )
    server, to_send = take!(send_channel)
    send(send_socket, server.host, server.port, to_send)
    return "send_to", server
end


function handle(
        socket::UDPSocket,
        server::Server,
        file::String,
        numbytes::Int,
        chunks::Channel,
        recv_channels::Dict{Server, Channel{Any}},
        send_channel::Channel{Tuple{Server, Array{UInt8,1}}},
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

    @info "Starting handle for $server."
    while !done
        tries = 0
        while server_state == states[1] # waiting for file
            @info "$server: $server_state."
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
                    put!(send_channel, (server, cat(h, bs, dims=1)))
                    bs = read(io, numbytes)
                end
            end
            r = take!(recv_channels[server])
            if r == confirmcode
                @info "$server got the whole file, moving to state 2."
                server_state = states[2]
            else
                @error "$server did not get the whole file. Retrying ($tries/$maxtries)"
                tries > maxtries && return (false, server)  # just give up talking to this server at this point.
            end
        end

        tries = 0
        chunk = take!(chunks)
        while server_state == states[2]  # waiting for job
            @info "$server: $server_state."
            tries += 1

            put!(send_channel, (server, reinterpret(UInt8, [chunk.start, chunk.stop])))
            r = take!(recv_channels[server])
            if r == confirmcode
                @info "$server started working on pixels $chunk, moving to state 3."
                server_state = states[3]
            else
                @error "Sending job to $server failed, retrying ($tries/$maxtries)"
                tries > maxtries && (put!(chunks, chunk); return (false, server))  # just give up talking to this server at this point.
                sleep(0.1)  # wait some time to give other threads a chance to take that chunk.
            end
        end

        tries = 0
        r = UInt8[]
        while server_state == states[3]  # processing job
            @info "$server: $server_state."
            tries += 1

            r = take!(recv_channels[server])
            # if the length of what we got is shorter/longer than what we expected, or if recv timed out
            # if we've tried too many times, send chunk back to chunks and return
            if length(r) != (chunk.stop - chunk.start + 1)*3 || r == errorcode
                @error "$server sent back a strange result or error. Expected length: $((chunk.stop - chunk.start + 1)*3) Got: $(length(r))."
                tries > maxtries && (put!(chunks, chunk); return (false, server))
                put!(send_channel, (server, errorcode))
            else
                @info "$server sent back completed chunk $chunk. Moving to state 4."
                put!(send_channel, (server, confirmcode))
                server_state = states[4]
            end
        end

        if server_state == states[4]  # finished
            @info "$server: $server_state."
            put!(final_image_channel, (chunk, r))
            server_state = states[2]
            !isready(chunks) && (done = true)
        end
    end
    @info "Finished with $server."
    return "handle", server
end


function update_final_image(
        final_image::Array{Union{Missing, UInt8}, 2},
        final_image_channel::Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}
    )
    chunk, result = take!(final_image_channel)
    final_image[chunk, :] = transpose(reshape(result, 3, div(length(result), 3)))
    percentage_missing = 100.0 - count(ismissing, final_image) / length(final_image) * 100
    return "update_final_image", percentage_missing
end

# TODO: client resends scene file after delay, work will need to happen server side. scene=1, job=0?
function main()
    if length(ARGS) != 3
        println("Usage: julia $PROGRAM_FILE [scene file] [server file] [ppm file name]")
        return nothing
    end
    server_list = map(i -> Server(getaddrinfo(i), 9105), readlines(ARGS[2]))

    file = ARGS[1]
    view, scene = parseFile(file)

    send_socket = UDPSocket()
    bind(send_socket, ip"127.0.0.1", 6105)
    recv_socket = UDPSocket()
    bind(recv_socket, ip"127.0.0.1", 5105)

    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk
    N = view.height * view.width  # Total number of pixels in image
    num_chunks = ceil(Int, N/numpixels)

    final_image = Array{Union{UInt8, Missing}}(missing, N, 3)
    final_image_channel = Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}(num_chunks)

    chunks = Channel{UnitRange{Int64}}(num_chunks)  # Tracks chunks, or individual jobs.
    for chunk in [i+1:i+numpixels for i in 0:numpixels:N]
        chunk.stop > N && (chunk = chunk.start:N)  # trim last chunk to only cover up to the end of the image, no further
        put!(chunks, chunk)
    end

    recv_channels = Dict(server => Channel(Inf) for server in server_list)
    send_channel = Channel{Tuple{Server, Array{UInt8,1}}}(Inf)

    tasklist = Array{Any, 1}(undef, 0)
    push!(tasklist, Task(() -> receive_from(recv_socket, recv_channels)))
    push!(tasklist, Task(() -> send_to(send_socket, send_channel)))
    push!(tasklist, Task(() -> update_final_image(final_image, final_image_channel)))
    tasklist = [(:take, schedule(t)) for t in tasklist]

    threadlist = [
        @spawn handle(server, file, numbytes, chunks, recv_channels, send_channel, final_image_channel)
        for server in server_list
    ]

    @info "Starting."
    while any(ismissing, final_image)  # while image is not completed
        i, r = select(tasklist)  # i is index of tasklist, r is return value of first function to return

        if r[1] == "update_final_image"
            print("Final image percentage complete: %$(round(r[2], digits=2))\r")
            tasklist[i] = (:take, schedule(Task(() -> update_final_image(final_image, final_image_channel))))
        elseif r[1] == "receive_from"
            tasklist[i] = (:take, schedule(Task(() -> receive_from(recv_socket, recv_channels))))
        elseif r[1] == "handle"
            println("Finished with server $(r[2]).")
        end
    end

    close(recv_socket)
    close(send_socket)
    final_image = permutedims(reshape(final_image, view.height, view.width, 3), [2, 1, 3])
    writePPM(ARGS[3], final_image)
    return
end

main()
