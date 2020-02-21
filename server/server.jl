using Sockets

include("raytracer.jl")
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
    bind(sock, ip"127.0.0.1", 9105)

    confirmcode = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    scenefile = ""
    scenehash = nothing
    firstclient = ()

    done = false
    debug = false

    println("Ready")
    while !done
        # TODO Test if correct client; add temporary bias to receive from previous client - might be done
        # follow up on above TODO: create a dictionary like client -> scenefile, checking that each file is complete against its hash,
        # based on what client the server is receiving from.
        while scenehash != hash(scenefile) && server_state == states[1]  # waiting for file
            debug && println(server_state)

            client, r = recvfrom(sock)
            firstclient == () && (firstclient = client)
            # println("Firstclient == client? $(firstclient == client). Got $(length(r)) bytes. Scenehash is $scenehash, scenefile hash is $(hash(scenefile)).")
            client != firstclient && (send(sock, client.host, client.port, errorcode); println("Heard from a different client than expected, continuing.."); continue)
            # println("Got $(length(r)) bytes from $client. Firstclient is $firstclient. Scenehash is $scenehash, scenefile hash is $(hash(scenefile)).")
            if r == confirmcode  # if r is confirm and the scene file isn't complete yet, send error and restart
                println("Got confirm code before expected, retrying...")
                send(sock, client.host, client.port, errorcode)
                scenefile = ""
                scenehash = nothing
                client = ()
                continue
            end

            scenehash = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
            scenefile *= String(copy(r[9:end]))
            scenehash == hash(scenefile) && (server_state = states[2])
            scenehash == hash(scenefile) && send(sock, firstclient.host, firstclient.port, confirmcode)  # got the whole file at this point
        end

        view, scene = parseFile(IOBuffer(scenefile))

        chunk = 0:0
        while server_state == states[2]  # waiting for job
            debug && println(server_state)
            client, r = recvfrom(sock)
            client != firstclient && (println("error in state 2 client=$client, firstclient=$firstclient"); send(sock, client.host, client.port, errorcode); continue)
            length(r) != 16 && (println("error in state 2 length(r)=$(length(r))"); send(sock, client.host, client.port, errorcode); continue)
            r = reinterpret(Int64, r)
            chunk = r[1]:r[2]
            send(sock, client.host, client.port, confirmcode)
            server_state = states[3]
        end

        bmp = collect(Iterators.flatten(eachrow(render(view, scene, chunk))))  # this can be directly sent.
        while server_state == states[3]  # processing job
            debug && println(server_state)
            send(sock, firstclient.host, firstclient.port, bmp)
            client, r = recvfrom(sock)  # should we assume that client is equal to firstclient at this point?
            r == confirmcode && (server_state = states[4])
        end

        if server_state == states[4]
            debug && println(server_state)
            server_state = states[2]
        end
    end
    close(sock)
end


main()