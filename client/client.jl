using Sockets

include("extra/Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

include("../julia/raytracer.jl")
using .RayTracer

#=
create a bucket of work that needs to be filled.
divide up the work between servers defined in SERVER_LIST
send work to each server
while waiting, do own work
if data is sent back, add it to the final image
=#


"""
Send a file to a server.

`socket` is a UDPSocket bound to the client ip address
`server` is a single tuple containing an ip address and a port number
"""
function sendfile(
    socket::UDPSocket,
    server_list::Array{Tuple{IPv4,Int64},1},
    file::String,
    numbytes::Int = 500
    )
    open(file, "r") do io
        # converts the UInt64 hash to an array of UInt8 partial hashes.
        h = reinterpret(UInt8, [hash(read(io, String))])
        seekstart(io)

        # the server will have to know to connect the first 8 bytes of file-sending messages to form the file hash
        bs = read(io, numbytes)
        for server in server_list
            while length(bs) > 0
                # send 500-byte packets, adding the file hash (8 bytes) to the beginning of each message
                send(socket, server[1], server[2], cat(h, bs, dims=1))
                bs = read(io, numbytes)
            end
        end
    end
end


function sendjob(socket::UDPSocket, server::Tuple{IPv4,Int64}, r::UnitRange)
    send(socket, server[1], server[2], reinterpret(UInt8, [r.start, r.stop]))
end


function main()
    server_list = [
        (ip"127.0.0.1", 3000)
    ]
    file = "client/default.scene"
    numbytes = 500  # Max bytes to send via UDP
    numpixels = floor(Int, numbytes/3)  # Number of pixels per chunk

    view, scene = parseFile(file)
    N = view.width * view.height  # Total number of pixels in image

    tracking = Dict()  # Tracks pixel chunks waiting for from servers
    for (i, chunk) in enumerate([i+1:i+numpixels for i in 0:numpixels:N])
        tracking[chunk] = [server_list[i % length(server_list)], 0]  # [server, waittime]
    end
    @show tracking

    socket = UDPSocket()
    bind(socket, ip"127.0.0.1", 3001)

    sf = @async sendfile(socket, server_list, file, 500)
    sj = @async sendjob()
    # r  = @async recvfrom(socket)
    while true
        @select begin
            sf => begin
                println("Sent $file to the server(s)")
            end

        end
    end
    close(socket)
end

main()