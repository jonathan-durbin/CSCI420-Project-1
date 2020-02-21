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
    bind(sock, ip"127.0.0.1", 9105)

    confirmcode = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    scenefile = ""
    scenehash = nothing
    firstclient = ()
    done = false

    @info "Ready."
    #=
    TODO: create a dictionary like client -> scenefile, checking that each file is complete against its hash,
    based on what client the server is receiving from.
    =#
    while !done
        while scenehash != hash(scenefile) && server_state == states[1]  # waiting for file
            client, r = recvfrom(sock)
            @info "Got $(length(r)) bytes from client $(client.host) $(client.port)."
            firstclient == () && (firstclient = client)
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
            if scenehash == hash(scenefile)  # got the whole file at this point
                send(sock, firstclient.host, firstclient.port, confirmcode)
            end
        end
        @info "Got the whole scene file from $(firstclient.host) $(firstclient.port), resetting..."
        sleep(1)
        scenefile = ""
        scenehash = nothing
        firstclient = ()
    end
    close(sock)
end

main()