module Server

using Sockets
import Base.Threads.@spawn

include("raytracer.jl")
using .RayTracer

include("Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select


# TODO: check if this is actually needed
struct Client
    host::IPv4
end

mutable struct Scene
    s::String  # string that describes scene
    h::Union{Nothing, UInt64}  # scene hash
end


# TODO: come up with a better name for this function
function recvfrom_into_channel(
        receive_socket::UDPSocket,
        receive_channels::Dict{Client,Channel{Array{UInt8,1}}}
    )
    address, data = recvfrom(receive_socket)
    client = Client(address.host)
    @debug "Got $(length(data)) bytes from $client."
    # initialize a new channel if this is a new client
    if !(client in keys(receive_channels))
        receive_channels[client] = Channel{Array{UInt8,1}}(Inf)
    end
    # put the data in the channel specific to this client
    put!(receive_channels[client], r)
    return client
end


function send_from_channel(
        send_socket::UDPSocket,
        send_channel::Channel{Tuple{Client, Array{UInt8,1}}},
        port::Int
    )
    client, data = take!(send_channel)
    send(send_socket, client.host, port, data)
    return client
end


function handle(
        client::Client,
        receive_channels::Dict{Client,Channel{Array{UInt8,1}}},
        send_channel::Channel{Tuple{Client, Array{UInt8,1}}},
        scene_dict::Dict{Client, Scene}
    )
    @enum states begin
        waiting_for_file
        waiting_for_job
        processing_job
        finished
    end
    server_state = waiting_for_file

    confirmcode = UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
    errorcode   = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    done = false

    # scene_dict[client] = Scene("", nothing)

    @info "Handling $client."
    while !done
        scene = get!(scene_dict, client, Scene("", nothing))
        while hash(scene.s) != scene.h && server_state == waiting_for_file
            @debug "$server_state, $client"

            r = take!(receive_channels[client])
            if r == confirmcode  # if r is confirm and the scene file isn't complete yet, send error and restart
                @error "Got confirm code before expected, retrying..."
                put!(send_channel, (client, errorcode))
                scene = Scene("", nothing)
                continue
            end
            scene.h = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
            scene.s *= String(copy(r[9:end]))
            if scene.h == hash(scene_dict[client][1])
                put!(send_channel, (client, confirmcode))  # got the whole file at this point
                server_state = waiting_for_job
            end
            scene_dict[client] = scene
            scene = scene_dict[client]
        end

        view, scene = parseFile(IOBuffer(scene_dict[client][1]))

        chunk = 0:0
        while server_state == waiting_for_job
            @debug "$server_state, $client"
            r = take!(receive_channels[client])
            if length(r) != 16
                @error "error in state 2 length(r)=$(length(r))"
                put!(send_channel, (client, errorcode))
                continue
            end
            r = reinterpret(Int64, r)
            chunk = r[1]:r[2]
            put!(send_channel, (client, confirmcode))
            server_state = processing_job
        end

        @info "Rendering $chunk for $client."
        bmp = collect(Iterators.flatten(eachrow(render(view, scene, chunk))))  # this can be directly sent.
        @debug "Done, sending..."
        while server_state == processing_job
            put!(send_channel, (client, bmp))
            r = take!(receive_channels[client])
            r == confirmcode && (server_state = finished)
        end

        if server_state == finished
            @debug "$server_state, $client"
            server_state = waiting_for_job
        end
    end
end


function print_waiting(n::Int, b::Bool)
    sleep(n)
    if b
        println("Waiting...")
    end
end


function main()
    send_sock = UDPSocket()
    receive_socket = UDPSocket()
    bind(receive_socket, ip"0.0.0.0", 9105)
    send_to_port = 6105

    receive_channels = Dict{Client,Channel{Array{UInt8,1}}}()
    send_channel = Channel{Tuple{Client, Array{UInt8,1}}}(Inf)
    scene_dict = Dict{Client, Scene}()
    clientlist = Client[]

    r = @async recvfrom_into_channel(receive_socket, receive_channels, clientlist)
    s = @async send_from_channel(send_sock, send_channel, send_to_port)
    w = @async print_waiting(5, true)

    @info "Main loop starting."
    while true
        @select begin
            r |> client => begin
                @debug "Received from $client."
                if !(client in clientlist)
                    @info "Now handling new $client."
                    @spawn handle(client, receive_channels, send_channel, scene_dict)
                    push!(clientlist, client)
                end
                r = @async recvfrom_into_channel(receive_socket, receive_channels, clientlist)
            end
            s |> client => begin
                @debug "Sent to $client."
                s = @async send_from_channel(send_sock, send_channel, send_to_port)
            end
            w => begin
                    b = length(clientlist) == 0
                    w = @async print_waiting(5, b)
            end
        end
    end
    close(send_sock)
    close(receive_socket)
end


main()

end  # module Server
