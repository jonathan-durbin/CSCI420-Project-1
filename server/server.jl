module Server

using Sockets
import Base.Threads.@spawn

include("raytracer.jl")
using .RayTracer

include("Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select


struct Client
    host::IPv4
end


function receive_from(
        recv_socket::UDPSocket,
        recv_channels::Dict{Client,Channel{Array{UInt8,1}}},
        clientlist::Array{Client,1}
    )
    resp = recvfrom(recv_socket)
    client, r = Client(resp[1].host), resp[2]
    @debug "Got $(length(r)) bytes from $client."
    if !(client in clientlist)
        recv_channels[client] = Channel{Array{UInt8,1}}(Inf)
    end
    # if we receive from a client, then put the data in the channel for the corresponding client
    put!(recv_channels[client], r)
    return client
end


function send_to(
        send_socket::UDPSocket,
        send_channel::Channel{Tuple{Client, Array{UInt8,1}}},
        send_to_port::Int
    )
    client, to_send = take!(send_channel)
    send(send_socket, client.host, send_to_port, to_send)
    return client
end


function handle(
        client::Client,
        recv_channels::Dict{Client,Channel{Array{UInt8,1}}},
        send_channel::Channel{Tuple{Client, Array{UInt8,1}}},
        scene_dict::Dict{Client, Array{Any, 1}}
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
    done = false

    scene_dict[client] = ["", nothing]  # scene file, scene hash

    @info "Handling $client."
    while !done
        while hash(scene_dict[client][1]) != scene_dict[client][2] && server_state == states[1]  # waiting for file
            @debug "$server_state, $client"

            r = take!(recv_channels[client])
            if r == confirmcode  # if r is confirm and the scene file isn't complete yet, send error and restart
                @error "Got confirm code before expected, retrying..."
                put!(send_channel, (client, errorcode))
                scene_dict[client] = ["", nothing]
                continue
            end
            scene_dict[client][2] = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
            scene_dict[client][1] *= String(copy(r[9:end]))
            scene_dict[client][2] == hash(scene_dict[client][1]) && put!(send_channel, (client, confirmcode))  # got the whole file at this point
            scene_dict[client][2] == hash(scene_dict[client][1]) && (server_state = states[2])
        end

        view, scene = parseFile(IOBuffer(scene_dict[client][1]))

        chunk = 0:0
        while server_state == states[2]  # waiting for job
            @debug "$server_state, $client"
            r = take!(recv_channels[client])
            length(r) != 16 && (@error "error in state 2 length(r)=$(length(r))"; put!(send_channel, (client, errorcode)); continue)
            r = reinterpret(Int64, r)
            chunk = r[1]:r[2]
            put!(send_channel, (client, confirmcode))
            server_state = states[3]
        end

        @info "Rendering $chunk for $client."
        bmp = collect(Iterators.flatten(eachrow(render(view, scene, chunk))))  # this can be directly sent.
        @debug "Done, sending..."
        while server_state == states[3]  # processing job
            put!(send_channel, (client, bmp))
            r = take!(recv_channels[client])
            r == confirmcode && (server_state = states[4])
        end

        if server_state == states[4]  # finished
            @debug "$server_state, $client"
            server_state = states[2]
        end
    end
end

function print_waiting(n::Int)
    sleep(n)
    println("Waiting...")
end


function main()
    send_sock = UDPSocket()
    recv_sock = UDPSocket()
    bind(recv_sock, ip"0.0.0.0", 9105)
    send_to_port = 6105

    recv_channels = Dict{Client,Channel{Array{UInt8,1}}}()
    send_channel = Channel{Tuple{Client, Array{UInt8,1}}}(Inf)
    scene_dict = Dict{Client, Array{Any,1}}()
    clientlist = Client[]

    r = @async receive_from(recv_sock, recv_channels, clientlist)
    s = @async send_to(send_sock, send_channel, send_to_port)
    w = @async print_waiting(5)

    @info "Main loop starting."
    while true
        @select begin
            r |> client => begin
                @debug "Received from $client."
                if !(client in clientlist)
                    @info "Now handling new $client."
                    @spawn handle(client, recv_channels, send_channel, scene_dict)
                    push!(clientlist, client)
                end
                r = @async receive_from(recv_sock, recv_channels, clientlist)
            end
            s |> client => begin
                @debug "Sent to $client."
                s = @async send_to(send_sock, send_channel, send_to_port)
            end
            w |> w => begin
                if length(clientlist) == 0
                    w = @async print_waiting(5)
                end
            end
        end
    end
    close(send_sock)
    close(recv_sock)
end


main()

end  # module Server
