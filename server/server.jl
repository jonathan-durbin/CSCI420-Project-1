using Sockets

include("../julia/raytracer.jl")
using .RayTracer

function main()
    sock = UDPSocket()
    bind(sock, ip"127.0.0.1", 8055)

    confirm = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    error   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    scenefile = ""
    scenehash = nothing
    client = ""

    # TODO Test if correct client; add temporary bias to receive from previous client
    while scenehash != hash(scenefile)
        global scenefile, scenehash, client, confirm, error

        client, r = recvfrom(sock)  # recv blocks execution.
        if r == confirm
            send(sock, client, 9055, error)
            scenefile = ""
            scenehash = nothing
            client = ""
            continue
        end
        scenehash = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
        scenefile = scenefile * String(r[9:end])
    end

    send(sock, client, 9055, confirm)

    println("Got the whole file!")
    scenebuffer = IOBuffer(scenefile)
    view, scene = parseFile(scenebuffer)

    ip = ""
    r = Int64
    while ip != client
        global ip, r
        ip, r = recvfrom(sock)
    end

# collect(Iterators.flatten(eachrow(render(view, scene, chunk))))  # this can be directly sent.

    close(sock)
end

main()