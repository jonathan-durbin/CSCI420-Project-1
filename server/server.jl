using Sockets

include("../julia/raytracer.jl")
using .RayTracer


function main()
    states = [
        "waiting for file",
        "waiting for job",
        "processing job",
        "finished"
    ]
    server_state = states[1]
    sock = UDPSocket()
    bind(sock, ip"127.0.0.1", 8055)

    confirmcode = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    scenefile = ""
    scenehash = nothing
    firstclient = ()

    # TODO Test if correct client; add temporary bias to receive from previous client - might be done
    while scenehash != hash(scenefile) && server_state == states[1]
        # global scenefile, scenehash, client, confirmcode, errorcode

        client, r = recvfrom(sock)
        firstclient == () && (firstclient = client)
        client != firstclient && send(sock, client.host, client.port, errorcode); continue
        if r == confirmcode  # if r is confirm and the scene file isn't complete yet, send error and restart
            send(sock, client.host, client.port, errorcode)
            scenefile = ""
            scenehash = nothing
            client = ()
            continue
        end

        scenehash = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
        scenefile *= String(copy(r[9:end]))
        scenehash == hash(scenefile) && (server_state = states[2])
    end

    send(sock, firstclient.host, firstclient.port, confirmcode)  # got the whole file at this point
    view, scene = parseFile(IOBuffer(scenefile))

    chunk = 0:0
    while server_state == states[2]
        client, r = recvfrom(sock)
        client != firstclient && send(sock, client.host, client.port, errorcode); continue
        length(r) != 16 && send(sock, client.host, client.port, errorcode)
        r = reinterpret(Int64, r)
        chunk = r[1]:r[2]
        send(sock, client.host, client.port, confirmcode)
        server_state = states[3]
    end

    bmp = collect(Iterators.flatten(eachrow(render(view, scene, chunk))))  # this can be directly sent.
    while server_state == states[3]
        send(sock, firstclient.host, firstclient.port, bmp)
        client, r = recvfrom(sock)  # should we assume that client is equal to firstclient at this point?
        r == confirmcode && (server_state = states[4])
    end

    close(sock)

    # if server_state == states[4]
    #     println("Finished!")
    #     close(sock)
    #     return true
    # else
    #     println("Not finished, restarting...!")
    #     close(sock)
    #     return false
    # end
end


while true
    main()
end