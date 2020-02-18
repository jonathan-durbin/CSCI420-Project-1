# Based on https://blogs.msdn.microsoft.com/lukeh/2007/04/03/a-ray-tracer-in-c3-0/

module RayTracer

export
    Scene, Plane, Sphere, Light, Viewport,
    checkerboard, shiny,
    createCamera, parseFile, writePPM,
    render


using LinearAlgebra

background = [0,0,0]
defaultColor = [0,0,0]

toByte(x) = trunc(UInt8, min(255, x * 255))

struct Ray
    start::Array{Float64,1}
    dir  ::Array{Float64,1}
end

struct Surface
    diffuse
    specular
    reflect
    roughness::Float64
end

shiny = Surface(
    p -> [1,1,1],
    p -> [0.5,0.5,0.5],
    p -> 0.6,
    50.0
)

checkerboard = Surface(
    p -> (floor(p[3]) + floor(p[1])) % 2 != 0 ? [1,1,1] : [0,0,0],
    p -> [1,1,1],
    p -> (floor(p[3]) + floor(p[1])) % 2 != 0 ? 0.1 : 0.7,
    150.0
)

struct Camera
    pos    ::Array{Float64,1}
    forward::Array{Float64,1}
    up     ::Array{Float64,1}
    right  ::Array{Float64,1}
end

function createCamera(pos, lookat)
    forward = normalize(lookat - pos)
    down = [0, -1, 0]
    right = 1.5 * normalize(cross(forward, down))
    up = 1.5 * normalize(cross(forward, right))
    return Camera(pos, forward, up, right)
end

struct Light
    pos  ::Array{Float64,1}
    color::Array{Float64,1}
end

struct Plane
    norm   ::Array{Float64,1}
    offset ::Float64
    surface::Surface
end

struct Sphere
    center ::Array{Float64,1}
    radius ::Float64
    surface::Surface
end

Thing = Union{Plane, Sphere}

struct Scene
    things::Array{Thing,1}
    lights::Array{Light,1}
    camera::Camera
end

struct ISect
    thing::Thing
    ray  ::Ray
    dist ::Float64
end

function intersect(thing::Plane, ray::Ray)
    denom = dot(thing.norm, ray.dir)
    if denom > 0
        return Nothing  # might need to be "nothing"
    else
        d = (dot(thing.norm, ray.start) + thing.offset) / (-denom)
        return ISect(thing, ray, d)
    end
end

function intersect(thing::Sphere, ray::Ray)
    eo = thing.center - ray.start
    v = dot(eo, ray.dir)
    if v > 0
        disc = thing.radius^2 - (dot(eo,eo) - v^2)
        dist = disc < 0 ? 0 : v - sqrt(disc)
        if dist == 0
            return Nothing
        else
            return ISect(thing,ray,dist)
        end
    else
        return Nothing
    end
end

function normal(thing::Plane, pos)
    return thing.norm
end

function normal(thing::Sphere, pos)
    return normalize(pos - thing.center)
end

struct Viewport
    width ::Int
    height::Int
end

function recenterX(view::Viewport, x)
    return (x - view.width / 2) / (2 * view.width)
end

function recenterY(view::Viewport, y)
    return -(y - view.height/2) / (2*view.height)
end

function getPoint(view::Viewport,camera::Camera,x,y)
    return normalize(camera.forward +
        recenterX(view, x)*camera.right +
        recenterY(view, y)*camera.up)
end

function getNaturalColor(thing::Thing, pos, n, rd, scene::Scene)
    ret = [0,0,0]
    for light = scene.lights
        ldis = light.pos - pos
        livec = normalize(ldis)
        neatIsect = testRay(Ray(pos, livec), scene)
        isInShadow = !((neatIsect > norm(ldis)) || neatIsect == 0)
        if !isInShadow
            illum = dot(livec, n)
            lcolor = illum > 0 ? illum * light.color : [0,0,0]
            specular = dot(livec, normalize(rd))
            scolor = specular > 0 ? (specular^thing.surface.roughness) * light.color : [0,0,0]
            ret = ret + map(*,thing.surface.diffuse(pos), lcolor)+
                        map(*,thing.surface.specular(pos), scolor)
        end
    end
    return ret
end

function getReflectionColor(thing::Thing, pos, n, rd, scene::Scene, depth)
    return thing.surface.reflect(pos)*traceRay(Ray(pos, rd), scene, depth+1)
end

global maxDepth = 5

function shade(isect::ISect, scene::Scene, depth)
    d = isect.ray.dir
    pos = isect.dist*isect.ray.dir + isect.ray.start
    n = normal(isect.thing, pos)
    reflectDir = d - 2*dot(n, d)*n
    ret = defaultColor + getNaturalColor(isect.thing, pos, n, reflectDir, scene)
    if depth >= maxDepth
        return ret + [0.5, 0.5, 0.5]
    end
    return ret + getReflectionColor(isect.thing, pos + (0.001*reflectDir), n, reflectDir, scene, depth)
end

function firstIntersection(ray::Ray, scene::Scene)
    vs = scene.things |>
            t -> map(o -> intersect(o,ray), t) |>
            t -> filter(i -> i != Nothing, t) |>
            t -> sort(by=i->i.dist, t)
    if length(vs) == 0
        return Nothing
    end
    return first(vs)
end

function testRay(ray::Ray, scene::Scene)
    isect = firstIntersection(ray, scene)
    if isect == Nothing
        return 0
    end
    return isect.dist
end

function traceRay(ray::Ray, scene::Scene, depth)
    isect = firstIntersection(ray, scene)
    if isect == Nothing
        return background
    end
    return shade(isect, scene, depth)
end

function render(view::Viewport, scene::Scene, range::UnitRange{Int64} = 1:view.width*view.height)
    if range == 1:view.width*view.height
        bitmap = zeros(UInt8, (view.width, view.height, 3))
        default = true
    else
        bitmap = zeros(UInt8, (range.stop - range.start + 1, 3))
        default = false
    end
    for (i, val) = enumerate(range)
        y = val % view.height + 1
        x = ceil(Int, val / view.height)
        c = traceRay(Ray(scene.camera.pos, getPoint(view,scene.camera, x-1, y-1)), scene, 0)
        if default
            bitmap[x,y,:] = map(toByte, c)
        else
            bitmap[i, :] = map(toByte, c)
        end
    end
    # !default && (bitmap = reshape(bitmap, (view.width, view.height, 3)))  # probably don't need this
    return bitmap
end

function writePPM(filename, bitmap)
    w = size(bitmap, 1)
    h = size(bitmap, 2)
    header = "P3 $(w) $(h) 255\n"
    open(filename, "w") do io
        println(io, header)
        for y = 1:h
            for x = 1:w
                print(io, "$(bitmap[x,y,1]) $(bitmap[x,y,2]) $(bitmap[x,y,3]) ")
            end
            println(io, "")
        end
    end
end

function simpleSurface(diffuse, reflect, roughness)
    return Surface(p -> diffuse, p -> [0.5, 0.5, 0.5], p -> reflect, 200.0*roughness)
end

function parseFile(file)
    if typeof(file) == String
        open(file, 'r') do io
            file = IOBuffer(io)
        end
    end
    view = Viewport(600,600)
    things = []
    lights = []
    camera = Nothing
    for rawl in eachline(file)
        l = split(rawl,"#")
        if length(l) == 0
            continue
        end
        ws = split(l[1], " ", keepempty=false)
        if length(ws) != 0
            if ws[1] == "#"
            elseif ws[1] == "sphere"
                @assert(length(ws) == 1+9, "sphere requires 9 values, saw $(length(ws)-1):\n\t$(ws)")
                vs = map(x -> parse(Float64,x), ws[2:10])
                things = [things; Sphere(vs[1:3], vs[4], simpleSurface(vs[5:7],vs[8],vs[9]))]
            elseif ws[1] == "light"
                @assert(length(ws) == 1+6, "light requires 6 values, saw $(length(ws)-1):\n\t$(ws)")
                vs = map(x -> parse(Float64,x), ws[2:7])
                n = maximum(vs[4:6])
                n = n < 1 ? 1 : n
                lights = [lights; Light(vs[1:3], vs[4:6]/n)]
            elseif ws[1] == "camera"
                @assert(length(ws) == 1+6, "camera requires 6 values, saw $(length(ws)-1):\n\t$(ws)")
                vs = map(x -> parse(Float64,x), ws[2:7])
                camera = createCamera(vs[1:3], vs[4:6])
            elseif ws[1] == "view"
                @assert(length(ws) == 1+2, "view requires 2 values, saw $(length(ws)-1):\n\t$(ws)")
                vs = map(x -> parse(UInt32,x), ws[2:3])
                view = Viewport(vs[1], vs[2])
            end
        end
    end
    @assert(camera != Nothing)
    return (view, Scene(things, lights, camera))
end

end  # module RayTracer


if abspath(PROGRAM_FILE) == @__FILE__
    using .RayTracer
    demoScene = Scene(
        [
            Plane([0, 1, 0], 0, checkerboard),
            Sphere([0,1,0], 1, shiny),
            Sphere([-1,0.5,1.5], 0.5, shiny)
        ],
        [
            Light([ -2,2.5,   0], [.49,.07,.07 ]),
            Light([1.5,2.5, 1.5], [.07,.07,.49 ]),
            Light([1.5,2.5,-1.5], [.07,.49,.071]),
            Light([  0,3.5,   0], [.21,.21,.35 ])
        ],
        createCamera([3,2,4],[-1,0.5,0])
    )

    if length(ARGS) == 2
        println("Reading $(ARGS[1])\nOutput $(ARGS[2])")
        r = parseFile(ARGS[1])
        if r != Nothing
            view, scene = r
            println("""Rendering $(view.width)x$(view.height) scene
                    Things: $(length(scene.things))
                    Lights: $(length(scene.lights))""")
            time = @elapsed bmp = render(view, scene)
            println("Done $(time) seconds")
            writePPM(ARGS[2], bmp)
        end
    elseif length(ARGS) == 1 && ARGS[1] == "--demo"
        bmp = render(Viewport(400, 400), demoScene)
        writePPM("demo.ppm", bmp)
    else
        println("Usage: raytracer [scene file] [output ppm]")
    end
end