using Sockets
include("Select.jl") # From https://github.com/NHDaly/Select.jl/blob/master/src/Select.jl
using .Select

# written by Ryan Yates in his Networking class.

function main()
    sock = UDPSocket()
    bind(sock, ip"127.0.0.1", 9001)

    t = @async recvfrom(sock)
    d = @async sleep(5)
    k = @async readline()

    while true
        @select begin
            t |> r => begin
                        from,data = r
                        println("$(from.host): $(String(copy(data)))")
                        t = @async recvfrom(sock)
                      end
            d      => begin
                        println("5 seconds have passed.")
                        d = @async sleep(5)
                      end
            k |> s => begin
                        println("You wrote: $(s)")
                        k =  @async readline()
                      end
                end
    end
end

main()