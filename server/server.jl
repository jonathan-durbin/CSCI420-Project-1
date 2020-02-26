using Sockets
import Base.Threads.@spawn

include("raytracer.jl")
using .RayTracer

include("Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select


struct Client
    host::IPv4
    port::Int
end

function receive_from(
        recv_socket::UDPSocket,
        recv_channels::Dict{Client,Channel{Any}},
        clientlist::Array{Client,1}
    )
    resp = recvfrom(recv_socket)
    client, r = Client(resp[1].host, resp[1].port), resp[2]
    @debug "Got $(length(r)) bytes from $client."
    if !(client in clientlist)
        recv_channels[client] = Channel(Inf)
    end
    # if we receive from a client, then put the data in the channel for the corresponding client
    put!(recv_channels[client], r)
    return client
end


function send_to(
        send_socket::UDPSocket,
        send_channel::Channel{Tuple{Client, Any}}
    )
    client, to_send = take!(send_channel)
    send(send_socket, client.host, client.port, to_send)
    return client
end


function handle(
        client::Client,
        recv_channels::Dict{Client,Channel{Any}},
        send_channel::Dict{Client,Channel{Any}}
    )
    states = [
        "waiting for file",
        "waiting for job",
        "processing job",
        "finished"
    ]
    server_state = states[1]

    confirmcode = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

    scenefile = ""
    scenehash = nothing

    done = false
    debug = false

    @info "Ready"
    while !done
        # TODO Test if correct client; add temporary bias to receive from previous client - might be done
        # follow up on above TODO: create a dictionary like client -> scenefile, checking that each file is complete against its hash,
        # based on what client the server is receiving from.
        while scenehash != hash(scenefile) && server_state == states[1]  # waiting for file
            @info "$server_state"

            r = take!(recv_channels[client])
            # println("Firstclient == client? $(firstclient == client). Got $(length(r)) bytes. Scenehash is $scenehash, scenefile hash is $(hash(scenefile)).")
            # client != firstclient && (send(sock, client.host, client.port, errorcode); println("Heard from a different client than expected, continuing.."); continue)
            # println("Got $(length(r)) bytes from $client. Firstclient is $firstclient. Scenehash is $scenehash, scenefile hash is $(hash(scenefile)).")
            if r == confirmcode  # if r is confirm and the scene file isn't complete yet, send error and restart
                @info "Got confirm code before expected, retrying..."
                put!(send_channel, (client, errorcode))
                scenefile = ""
                scenehash = nothing
                client = ()
                continue
            end

            scenehash = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
            scenefile *= String(copy(r[9:end]))
            scenehash == hash(scenefile) && put!(send_channel, (client, confirmcode))  # got the whole file at this point
            scenehash == hash(scenefile) && (server_state = states[2])
        end

        view, scene = parseFile(IOBuffer(scenefile))

        chunk = 0:0
        while server_state == states[2]  # waiting for job
            @info "$server_state"
            r = take!(recv_channels[client])
            length(r) != 16 && (@error "error in state 2 length(r)=$(length(r))"; put!(send_channel, (client, errorcode)); continue)
            r = reinterpret(Int64, r)
            chunk = r[1]:r[2]
            put!(send_channel, (client, confirmcode))
            server_state = states[3]
        end

        @info "Rendering $chunk for $client."
        bmp = collect(Iterators.flatten(eachrow(render(view, scene, chunk))))  # this can be directly sent.
        @info "Done, sending..."
        while server_state == states[3]  # processing job
            put!(send_channel, (client, bmp))
            r = take!(recv_channels[client])
            r == confirmcode && (server_state = states[4])
        end

        if server_state == states[4]  # finished
            @info "$server_state"
            server_state = states[2]
        end
    end
end


function main()
    send_sock = UDPSocket()
    bind(send_sock, ip"127.0.0.1", 9105)
    recv_sock = UDPSocket()
    bind(recv_sock, ip"127.0.0.1", 7105)

    recv_channels = Dict{Client,Channel{Any}}()
    send_channel = Channel{Tuple{Client, Any}}(Inf)
    clientlist = Client[]

    r = @async receive_from(recv_sock, recv_channels, clientlist)
    s = @async send_to(send_sock, send_channel)

    @info "Ready."
    while true
        @select begin
            r |> client => begin
                @info "Received from $client."
                if !(client in clientlist)
                    @info "Now handling new client $client."
                    send_channel[client] = Channel(Inf)
                    @spawn handle(client, recv_channels, send_channel)
                    push!(clientlist, client)
                end
                r = @async receive_from(recv_sock, recv_channels, clientlist)
            end
            s |> client => begin
                @info "Sent to $client."
                s = @async send_to(send_sock, send_channel)
            end
        end
    end
    close(send_sock)
    close(recv_sock)
end


main()