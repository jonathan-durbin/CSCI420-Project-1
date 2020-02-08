using Sockets

# include("julia/raytracer.jl")
# using .RayTracer

sock = UDPSocket()
bind(sock, ip"127.0.0.1", 3000)

scene = ""
h = nothing

while h != hash(scene)
    global scene, h

    r = recv(sock)  # recv blocks execution.
    h = reinterpret(UInt64, r[1:8])[1]  # reinterpret combines an array of UInt8 to a single UInt64
    scene = scene * String(r[9:end])
end

println("Got the whole file!")
@show scene

close(sock)