using Sockets

include("Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
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
            server, r = Server(ip"127.0.0.1", 9105), error_code
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
    recv_channels::Dict{Server, Channel{Any}},
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
    @info "Entered handle for $server."

    while server_state == states[1] # waiting for file
        open(file, "r") do io
            # converts the UInt64 hash to an array of UInt8 partial hashes.
            h = reinterpret(UInt8, [hash(read(io, String))])
            seekstart(io)

            bs = read(io, numbytes)
            while length(bs) > 0
                # send numbytes-byte packets, adding the file hash (8 bytes) to the beginning of each message
                @info "Sending file to $server. Bytes remaining in file: $(length(bs))."
                send(socket, server.host, server.port, cat(h, bs, dims=1))
                bs = read(io, numbytes)
            end
        end
        # below line not needed
        # send(socket, server.host, server.port, confirmcode)
        ip, r = receive_from(socket, server, recv_channels, errorcode, 0.5)
        if r == confirmcode
            @info "Server $server got the whole file, moving on to state 2"
            server_state = states[2]
        else
            @error "Server $server did not get the entire file."
            return (false, server)
        end
    end

    return (true, server)
end


function main()
    if length(ARGS) != 2
        println("Usage: julia $PROGRAM_FILE [scene file] [server file]")
        return nothing
    end
    server_list = readlines(ARGS[2])
    server_list = map(i -> Server(getaddrinfo(i), 9105), server_list)
    @info "List of servers: $server_list"

    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 8105)
    file = ARGS[1]
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    recv_channels = Dict(server => Channel(1) for server in server_list)

    tasks = Array{Any, 1}(undef, length(server_list))
    map!(server ->
        () -> Task(() -> handle(socket, server, file, numbytes, recv_channels)),
        tasks,
        server_list
    )
    tasklist = [(:take, schedule(t())) for t in tasks]
    @info "Begin testing!"
    while true
        i, r = select(tasklist)  # i is index of server_list, r is return value of first function to return

        if r[1] == false  # timed out
            println("Timed out in main execution with server $(r[2]).")
            break
        elseif r[1] == true
            flag, server = r
            println("Finished with server $server.")
            return nothing
            # tasklist[i] = (:take, schedule(Task(() -> handle(socket, server_list[i], file, numbytes, recv_channels))))
        end
    end
    close(socket)
end

main()