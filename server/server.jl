using Sockets

include("../julia/raytracer.jl")
using .RayTracer

sock = UDPSocket()
bind(sock, ip"127.0.0.1", 5055)

confirm = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
error   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

scene = ""
h = nothing
client = ""

while h != hash(scene)
    global scene, h, client, confirm, error

    client, r = recvfrom(sock)  # recv blocks execution.
    if r == confirm
        send(sock, client, 9055, error)
        scene = ""
        h = nothing
        client = ""
        continue
    end
    h = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
    scene = scene * String(r[9:end])
end

send(sock, client, 9055, confirm)

println("Got the whole file!")
scenebuffer = IOBuffer(scene)


close(sock)