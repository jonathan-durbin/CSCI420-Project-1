using Sockets

include("./julia/raytracer.jl")
using .RayTracer

clisock = UDPSocket()
bind(clisock, ip"127.0.0.1", 3001)

job = "work"
server_list = [
    (ip"127.0.0.1", 3000)
]


#=
create a bucket of work that needs to be filled.
divide up the work between servers defined in server_list
send work to each server
while waiting, do own work
if data is sent back, add it to the final image
=#

if length(ARGS) == 2
    println("Reading $(ARGS[1])\nOutput $(ARGS[2])")
    f = parseFile(ARGS[1])
    if f != Nothing
        view, scene = f
        println("""Rendering $(view.width)x$(view.height) scene
                   Things: $(length(scene.things))
                   Lights: $(length(scene.lights))""")
        time = @elapsed bmp = render(view, scene)
        println("Done $(time) seconds")
        writePPM(ARGS[2], bmp)
    end
else
    println("Usage: julia [client file] [scene file] [output].ppm")
end


# while true
#     send(clisock, ip"127.0.0.1", 3000, job)
# end