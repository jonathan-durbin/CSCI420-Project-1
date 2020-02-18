using Sockets

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer


struct Server
    host::IPv4
    port::Int
end


function timeout(n::Int, v::Bool = false)
    sleep(n)
    v && println("Timed out")
    return false
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
    # FIXME: if above times out, server is now equal to a (probably) unexpected server, so this might not be good
    return (server, r)
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
    confirmcode  = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    maxtries = 5

    tries = 0
    while server_state == states[1]  # waiting for file
        tries += 1
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
        send(socket, server.host, server.port, confirmcode)
        ip, r = receive_from(socket, server, recv_channels, errorcode, 0.5)
        if r == confirmcode
            server_state = states[2]
        else
            tries > maxtries && return false, server  # just give up talking to this server at this point.
            println("Error while sending file to $server, retrying ($(tries/maxtries))...")
        end
    end

    tries = 0
    chunk = take!(chunks)
    while server_state == states[2]  # waiting for job
        tries += 1

        send(socket, server.host, server.port, reinterpret(UInt8, [chunk.start, chunk.stop]))
        ip, r = receive_from(socket, server, recv_channels, errorcode, 0.5)
        if r == confirmcode
            server_state = states[3]
        else
            put!(chunks, chunk)
            println("Error while sending job to $server, retrying ($(tries/maxtries))...")
            tries > maxtries && return false, server  # just give up talking to this server at this point.
            sleep(0.1)  # wait some time to give other tasks a chance to take that chunk.
        end
    end

    tries = 0
    r = UInt8[]
    while server_state == states[3]  # processing job
        tries += 1

        ip, r = receive_from(socket, server, recv_channels, errorcode, 1)
        # if the length of what we got is shorter/longer than what we expected,
        # or if recv timed out
        # if we've tried too many times, send chunk back to chunks and return
        if length(r) != chunk.stop - chunk.start + 1  || r == errorcode
            tries > maxtries && put!(chunks, chunk); return false, server
            send(socket, server.host, server.port, errorcode)
        else
            send(socket, server.host, server.port, confirmcode)
            server_state = states[4]
        end
    end

    if server_state == states[4]  # finished
        return true, server, chunk, r
    end
end


function main()
    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 9055)
    # getaddrinfo("D13055"), etc...
    server_list = [
        Server(ip"127.0.0.1", 5055)
    ]
    file = "client/default.scene"
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    view, scene = parseFile(file)
    final_image = Array{Union{UInt8, Missing}}(missing, view.height * view.width, 3)
    N = view.height * view.width  # Total number of pixels in image

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
    # TODO: create empty image (done), update it (done), know when to break the below loop when the image is finished (done), write the image ppm file
    while any(ismissing, final_image)  # while image is not completed
        i, r = select(tasklist)  # i is index of server_list, r is return value of first function to return
        @assert length(r) >= 2  # r should be at least (success_code, server), with more if its successful

        if r[1] == false  # timed out
            println("Timed out in main execution with server $(r[2]). All retries should already have been attempted.")
        else
            flag, server, chunk, result = r
            final_image[chunk, :] = transpose(reshape(result, 3, div(length(result), 3)))
            tasklist[i] = (:take, Task(() -> handle(socket, server_list[i], file, numbytes, chunks, recv_channels)))
        end
    end
    close(socket)
    final_image = reshape(final_image, view.height, view.width, 3)

end

main()