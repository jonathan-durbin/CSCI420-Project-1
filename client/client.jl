module Client

using Sockets
import Base.Threads.@spawn

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer


global bytes_recv = 0
global bytes_sent = 0

struct Server
    host::IPv4
end


function receive_from(
        recv_socket::UDPSocket,
        recv_channels::Dict{Server,Channel{Any}}
    )
    resp = recvfrom(recv_socket)
    server, r = Server(resp[1].host), resp[2]
    bytes_recv += length(r)
    @debug "Got $(length(r)) bytes from $server."
    # if we receive from a server, then put the data in the channel for the corresponding server
    put!(recv_channels[server], r)
    return server
end


function send_to(
        send_socket::UDPSocket,
        send_channel::Channel{Tuple{Server, Array{UInt8,1}}},
        send_to_port::Int
    )
    server, to_send = take!(send_channel)
    bytes_sent += length(to_send)
    send(send_socket, server.host, send_to_port, to_send)
    return server
end


function handle(
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
            @debug "$server: $server_state."
            tries += 1
            open(file, "r") do io
                # converts the UInt64 hash to an array of UInt8 partial hashes.
                h = reinterpret(UInt8, [hash(read(io, String))])
                seekstart(io)

                # the server will have to know to connect the first 8 bytes of file-sending messages to form the file hash
                bs = read(io, numbytes)
                while length(bs) > 0
                    # send numbytes-byte packets, adding the file hash (8 bytes) to the beginning of each message
                    @debug "Sending file to $server. Bytes remaining: $(length(bs))."
                    put!(send_channel, (server, cat(h, bs, dims=1)))
                    bs = read(io, numbytes)
                end
            end
            r = take!(recv_channels[server])
            if r == confirmcode
                @debug "$server got the whole file, moving to state 2."
                server_state = states[2]
            else
                @error "$server did not get the whole file. Retrying ($tries/$maxtries)"
                tries > maxtries && return (false, server)  # just give up talking to this server at this point.
            end
        end

        tries = 0
        chunk = take!(chunks)
        while server_state == states[2]  # waiting for job
            @debug "$server: $server_state."
            tries += 1

            put!(send_channel, (server, reinterpret(UInt8, [chunk.start, chunk.stop])))
            r = take!(recv_channels[server])
            if r == confirmcode
                @debug "$server started working on pixels $chunk, moving to state 3."
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
            @debug "$server: $server_state."
            tries += 1

            r = take!(recv_channels[server])
            # if the length of what we got is shorter/longer than what we expected, or if recv timed out
            # if we've tried too many times, send chunk back to chunks and return
            if length(r) != (chunk.stop - chunk.start + 1)*3 || r == errorcode
                @error "$server sent back a strange result or error. Expected length: $((chunk.stop - chunk.start + 1)*3) Got: $(length(r))."
                tries > maxtries && (put!(chunks, chunk); return (false, server))
                put!(send_channel, (server, errorcode))
            else
                @debug "$server sent back completed chunk $chunk. Moving to state 4."
                put!(send_channel, (server, confirmcode))
                server_state = states[4]
            end
        end

        if server_state == states[4]  # finished
            @debug "$server: $server_state."
            put!(final_image_channel, (chunk, r))
            server_state = states[2]
            !isready(chunks) && (done = true)
        end
    end
    @info "Finished with $server."
    return server
end


function update_final_image(
        final_image::Array{Union{Missing, UInt8}, 2},
        final_image_channel::Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}
    )
    chunk, result = take!(final_image_channel)
    final_image[chunk, :] = transpose(reshape(result, 3, div(length(result), 3)))
    percentage_missing = 100.0 - count(ismissing, final_image) / length(final_image) * 100
    return percentage_missing
end

# TODO: client resends scene file after delay, work will need to happen server side. scene=1, job=0 encoded in sent data?
function main()
    if length(ARGS) != 3
        println("Usage: julia $PROGRAM_FILE [scene file] [server file] [ppm file name]")
        return nothing
    end
    send_to_port = 9105
    server_list = map(i -> Server(getaddrinfo(i)), readlines(ARGS[2]))

    file = ARGS[1]
    view, scene = parseFile(file)

    recv_socket = UDPSocket()
    bind(recv_socket, ip"0.0.0.0", 6105)
    send_socket = UDPSocket()

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

    r = @async receive_from(recv_socket, recv_channels)
    s = @async send_to(send_socket, send_channel, send_to_port)
    u = @async update_final_image(final_image, final_image_channel)

    threadlist = [
        @spawn handle(server, file, numbytes, chunks, recv_channels, send_channel, final_image_channel)
        for server in server_list
    ]

    @info "Starting."
    start_time = time()
    while any(ismissing, final_image)  # while image is not completed
        @select begin
            r |> r => begin
                r = @async receive_from(recv_socket, recv_channels)
            end
            s |> s => begin
                s = @async send_to(send_socket, send_channel, send_to_port)
            end
            u |> u => begin
                print("Final image percentage complete: %$(round(u, digits=2))\r")
                u = @async update_final_image(final_image, final_image_channel)
            end
        end
    end

    close(recv_socket)
    close(send_socket)
    final_image = permutedims(reshape(final_image, view.height, view.width, 3), [2, 1, 3])
    writePPM(ARGS[3], final_image)
    println("Finished in $(round(time() - start_time, digits=3)) seconds.")
    println("Total bytes sent: $bytes_sent, total bytes received: $bytes_recv.")
    println("Average bandwidth: $((bytes_sent + bytes_recv)*8/(time() - start_time) / 1E6) Mbits/sec.")
    return
end

main()

end  # module Client
