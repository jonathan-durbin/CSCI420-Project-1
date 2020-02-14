using Sockets

include("../julia/raytracer.jl")
using .RayTracer

sock = UDPSocket()
bind(sock, ip"127.0.0.1", 5055)

confirm = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
error   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

scenein = ""
h = nothing
client = ""

# TODO Test if correct client; add temporary bias to receive from previous client
while h != hash(scenein)
    global scenein, h, client, confirm, error

    client, r = recvfrom(sock)  # recv blocks execution.
    if r == confirm
        send(sock, client, 9055, error)
        scenein = ""
        h = nothing
        client = ""
        continue
    end
    h = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
    scenein = scenein * String(r[9:end])
end

send(sock, client, 9055, confirm)

println("Got the whole file!")
scenebuffer = IOBuffer(scenein)
view, scene = parseFile(scenebuffer)

ip = ""
r = Int64
while ip != client
    global ip, r
    ip, r = recvfrom(sock)
end



close(sock)