using Sockets

include("julia/raytracer.jl")

servsock = UDPSocket()
bind(servsock, ip"127.0.0.1", 3000)

while true
    println(String(recv(servsock)))
end
