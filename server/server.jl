using Sockets

# include("julia/raytracer.jl")
# using .RayTracer

sock = UDPSocket()
bind(sock, ip"127.0.0.1", 3000)

scene = ""
h = nothing

while h != hash(scene, zero(UInt))
    global scene

    r = recv(sock)  # recv blocks execution.
    h = reinterpret(UInt64, r[1:8])[1]  # h is now an array of UInt8, but it needs to be combined to a single UInt64
    @show hash(scene, zero(UInt))
    @show h
    scene = scene * String(r[9:end])
    # @show scene
end

println("Got the whole file!")
println("Scene: $scene")

close(sock)