using Sockets

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer


# version 1
function handle(socket, server, file, numbytes, chunks)
    states = [
        "waiting for file",
        "waiting for job",
        "processing job",
        "finished"
    ]
    server_state = states[1]
    confirm = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    error   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    while server_state == "waiting for file"
        open(file, "r") do io
            # converts the UInt64 hash to an array of UInt8 partial hashes.
            h = reinterpret(UInt8, [hash(read(io, String))])
            seekstart(io)

            # the server will have to know to connect the first 8 bytes of file-sending messages to form the file hash
            bs = read(io, numbytes)
            while length(bs) > 0
                # send 500-byte packets, adding the file hash (8 bytes) to the beginning of each message
                send(socket, server[1], server[2], cat(h, bs, dims=1))
                bs = read(io, numbytes)
            end
        end
        send(socket, server[1], server[2], confirm)
        r = recv(socket)
        r == confirm ? server_state = states[2] : println("Error while sending file to $server, retrying...")
    end

    while server_state == "waiting for job"
        chunk = take!(chunks)
        send(socket, server[1], server[2], reinterpret(UInt8, [chunk.start, chunk.stop]))

        r = recv(socket)
        r == confirm ? server_state = states[3] : println("Error while sending job to $server, retrying...")
    end
end


function timeout(n)
    sleep(n)
    println("Timed out")
    return false
end


function main()
    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 9055)
    server_list = [
        (ip"127.0.0.1", 5055)
    ]
    file = "client/default.scene"
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    view, scene = parseFile(file)
    N = view.width * view.height  # Total number of pixels in image

    chunks = Channel{UnitRange{Int64}}(ceil(Int, N/numpixels)) do ch  # Tracks pixel chunks waiting for from servers
        for chunk in [i+1:i+numpixels for i in 0:numpixels:N]
            put!(ch, chunk)
        end
    end

    tasks = map(server ->
        () -> Task(() -> handle(socket, server, file, numbytes, chunks)),
        server_list
    )
    tasklist = [(:take, t()) for t in tasks]
    while true
        i, r = select(tasklist)  # i is index of server_list, r is return value of first function to return
    end

    close(socket)
end

main()