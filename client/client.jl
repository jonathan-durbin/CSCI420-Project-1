using Sockets

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer


struct Server
    host::IPv4
    port::Int
end


function receive_from(
    socket::UDPSocket,
    expected_server::Server,
    recv_channels::Dict{Server,Channel{Any}},
    error_code::Array{UInt8,1},
    n::Int
    )
    a = @async recvfrom(socket)
    b = @async timeout(n)  # if no response in n seconds, then return the error code
    @select begin
        a |> resp => begin
            server, r = Server(resp[1].host, resp[1].port), resp[2]
        end
        b => begin
            println("receive_from timed out waiting for $expected_server for $n seconds.")
            server, r = Server(ip"127.0.0.1", 9055), error_code
        end
    end
    # if we receive (successfully) from a server that we haven't been talking to,
    # then put the data in the channel for the corresponding server,
    # and try to take from the channel for the expected server
    if server != expected_server && r != error_code
        put!(recv_channels[server], r)
        r = take!(recv_channels[expected_server])
        server = expected_server  # r is now the data from the server that we expected, so server can be replaced
    end
    return (server, r)
end


function timeout(n::Int, v::Bool = false)
    sleep(n)
    v && println("Timed out")
    return false
end


function handle(
    socket::UDPSocket,
    server::Server,
    file::String,
    numbytes::Int,
    chunks::Channel,
    recv_channels::Channel
    )
    states = [
        "waiting for file",
        "waiting for job",
        "processing job",
        "finished"
    ]
    server_state = states[1]
    confirm = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    error   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    while server_state == states[1]  # waiting for file
        open(file, "r") do io
            # converts the UInt64 hash to an array of UInt8 partial hashes.
            h = reinterpret(UInt8, [hash(read(io, String))])
            seekstart(io)

            # the server will have to know to connect the first 8 bytes of file-sending messages to form the file hash
            bs = read(io, numbytes)
            while length(bs) > 0
                # send numbytes-byte packets, adding the file hash (8 bytes) to the beginning of each message
                send(socket, server.host, server.port, cat(h, bs, dims=1))
                bs = read(io, numbytes)
            end
        end
        send(socket, server.host, server.port, confirm)
        ip, r = receive_from(socket, server, recv_channels, error, 0.5)
        r == confirm ? server_state = states[2] : println("Error while sending file to $server, retrying...")
    end

    chunk = take!(chunks)
    while server_state == states[2]  # waiting for job
        send(socket, server.host, server.port, reinterpret(UInt8, [chunk.start, chunk.stop]))

        ip, r = receive_from(socket, server, recv_channels, error, 0.5)
        if r == confirm
            server_state = states[3]
        else
            put!(chunks, chunk)
            println("Error while sending job to $server, retrying...")
            sleep(0.1)  # wait some time to give other tasks a chance to take that chunk.
        end
    end

    r = UInt8[]
    while server_state == states[3]  # processing job
        ip, r = receive_from(socket, server, recv_channels, error, 0.5)
        if length(r) == chunk.stop - chunk.start + 1  # if the length of what we got is shorter/longer than what we expected
            send(socket, server.host, server.port, error)
        else
            send(socket, server.host, server.port, confirm)
            server_state = states[4]
        end
    end

    if server_state == states[4]  # finished
        return server, r
    end
end


function main()
    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 9055)
    server_list = [
        Server(ip"127.0.0.1", 5055)
    ]
    file = "client/default.scene"
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    view, scene = parseFile(file)
    final = zeros(view.height, view.width, 3)
    N = view.width * view.height  # Total number of pixels in image

    chunks = Channel{UnitRange{Int64}}(ceil(Int, N/numpixels)) do ch  # Tracks pixel chunks waiting for from servers
        for chunk in [i+1:i+numpixels for i in 0:numpixels:N]
            put!(ch, chunk)
        end
    end
    recv_channels = Dict(server => Channel(1) for server in server_list)

    tasks = map(server ->
        () -> Task(() -> handle(socket, server, file, numbytes, chunks, recv_channels)),
        server_list
    )
    tasklist = [(:take, t()) for t in tasks]

    while true  # while image is not completed
        i, r = select(tasklist)  # i is index of server_list, r is return value of first function to return
        # depending on the value of r
        if r == false  # timed out
            println("Timed out in main execution.")
        else
            tasklist[i] = (:take, Task(() -> handle(socket, server_list[i], file, numbytes, chunks, recv_channels)))
        end
    end

    close(socket)
end

main()