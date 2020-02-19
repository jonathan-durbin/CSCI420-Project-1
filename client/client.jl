using Sockets

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer


struct Server
    host::IPv4
    port::Int
end


function timeout(n::Union{Float64, Int64}, v::Bool = false)
    sleep(n)
    v && println("Timed out")
    return false
end


function receive_from(
    socket::UDPSocket,
    expected_server::Server,
    recv_channels::Dict{Server,Channel{Any}},
    error_code::Array{UInt8,1},
    n::Union{Float64, Int64}
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

    while !isready(chunks)  # CHECK: while chunks is empty?
        tries = 0
        while server_state == states[1] # waiting for file
            println(server_state)
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
            # send(socket, server.host, server.port, confirmcode)
            ip, r = receive_from(socket, server, recv_channels, errorcode, 0.5)
            if r == confirmcode
                server_state = states[2]
            else
                tries > maxtries && return (false, server)  # just give up talking to this server at this point.
                println("Error while sending file to $server, retrying ($(tries/maxtries))...")
            end
        end

        tries = 0
        chunk = take!(chunks)
        println(length(chunks.data))
        while server_state == states[2]  # waiting for job
            println(server_state)
            println("Chunk: ", chunk)
            tries += 1

            send(socket, server.host, server.port, reinterpret(UInt8, [chunk.start, chunk.stop]))
            ip, r = receive_from(socket, server, recv_channels, errorcode, 0.5)
            if r == confirmcode
                server_state = states[3]
            else
                println("Error while sending job to $server, retrying ($(tries/maxtries))...")
                tries > maxtries && (put!(chunks, chunk); return (false, server))  # just give up talking to this server at this point.
                sleep(0.1)  # wait some time to give other tasks a chance to take that chunk.
            end
        end

        tries = 0
        r = UInt8[]
        while server_state == states[3]  # processing job
            println(server_state)
            tries += 1

            ip, r = receive_from(socket, server, recv_channels, errorcode, 1)
            # if the length of what we got is shorter/longer than what we expected,
            # or if recv timed out
            # if we've tried too many times, send chunk back to chunks and return
            if length(r) != (chunk.stop - chunk.start + 1)*3 || r == errorcode
                tries > maxtries && (put!(chunks, chunk); return (false, server))
                send(socket, server.host, server.port, errorcode)
            else
                send(socket, server.host, server.port, confirmcode)
                server_state = states[4]
            end
        end

        if server_state == states[4]  # finished
            println(server_state)
            put!(final_image_channel, (chunk, r))
            # return (true, server, chunk, r)
            server_state = states[2]
        end
    end
end


function update_final_image(
    final_image::Array{Union{Missing, UInt8}, 2},
    final_image_channel::Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}
    )
    chunk, result = take!(final_image_channel)
<<<<<<< HEAD
    println(chunk, result)
=======
>>>>>>> 2d367e4e9312d36240507ea95723e85c5a8cf84b
    final_image[chunk, :] = transpose(reshape(result, 3, div(length(result), 3)))
    return
end


function main()
    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 9055)
    # getaddrinfo("D13055"), etc...
    server_list = [
        Server(ip"127.0.0.1", 8055)
    ]
    file = "client/default.scene"
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    view, scene = parseFile(file)
    final_image = Array{Union{UInt8, Missing}}(missing, view.height * view.width, 3)
    N = view.height * view.width  # Total number of pixels in image
    num_chunks = ceil(Int, N/numpixels)

    final_image_channel = Channel{Tuple{UnitRange{Int64}, Array{UInt8, 1}}}(num_chunks)
    chunks = Channel{UnitRange{Int64}}(num_chunks)  # Tracks pixel chunks waiting for from servers
    for chunk in [i+1:i+numpixels for i in 0:numpixels:N]
        put!(chunks, chunk)
    end
    recv_channels = Dict(server => Channel(1) for server in server_list)
    println("Initialised chunks, recv_channels, final_image_channel, view, scene.")

    tasks = Array{Any, 1}(undef, length(server_list))
    map!(server ->
        () -> Task(() -> handle(socket, server, file, numbytes, chunks, recv_channels, final_image_channel)),
        tasks,
        server_list
    )
    push!(tasks, () -> Task(() -> update_final_image(final_image, final_image_channel)))
    tasklist = [(:take, schedule(t())) for t in tasks]
    println("Created task list.")
    # TODO: create empty image (done), update it (done), know when to break the below loop when the image is finished (done), write the image ppm file
    while any(ismissing, final_image)  # while image is not completed
        println("Selecting from the task list.")
        i, r = select(tasklist)  # i is index of server_list, r is return value of first function to return
        println("Selected from the task list.")

        if isnothing(r)
            number_missing = count(ismissing, final_image)
            percentage_missing = 100.0 - number_missing / length(final_image) * 100
            println("Final image percentage complete: %$(round(percentage_missing, digits=2))")
            tasklist[i] = (:take, schedule(Task(() -> update_final_image(final_image, final_image_channel))))
            continue
        elseif r[1] == false  # timed out
            println("Timed out in main execution with server $(r[2]). All retries should already have been attempted.")
            break
        elseif length(r) == 4
            flag, server, chunk, result = r
            # println("Finished task $i, flag=$flag, server=$server, chunk=$chunk, result=$r.")
            # final_image[chunk, :] = transpose(reshape(result, 3, div(length(result), 3)))
            tasklist[i] = (:take, schedule(Task(() -> handle(socket, server_list[i], file, numbytes, chunks, recv_channels, final_image_channel))))
        end
    end
    close(socket)
    final_image = reshape(final_image, view.height, view.width, 3)
    writePPM("test.ppm", final_image)
end

main()