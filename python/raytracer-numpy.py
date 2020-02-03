import sys
import math
import time
import numpy as np
from collections import namedtuple
from numpy import dot, cross, sqrt

Ray = namedtuple("Ray", "start dir")
Surface = namedtuple("Surface", "diffuse specular reflect roughness")
Camera = namedtuple("Camera", "pos forward up right")
Light = namedtuple("Light", "pos color")
Plane = namedtuple("Plane", "norm offset surface")
Sphere = namedtuple("Sphere", "center radius surface")
Scene = namedtuple("Scene", "things lights camera")
ISect = namedtuple("ISect", "thing ray dist")

def vec(v):
    return np.array(v, np.float64)

background = vec([0,0,0])
defaultColor = vec([0,0,0])

def norm(v):
    return math.sqrt(dot(v,v))

def normalize(v):
    return v / norm(v)

shiny = Surface(\
    lambda p: vec([1,1,1]), \
    lambda p: vec([0.5,0.5,0.5]), \
    lambda p: 0.6,\
    50.0)

checkerboard = Surface(\
    lambda p: vec([1,1,1]) if ((math.floor(p[2]) + math.floor(p[0])) % 2 != 0) else vec([0,0,0]), \
    lambda p: vec([1,1,1]), \
    lambda p: 0.1 if (math.floor(p[2]) + math.floor(p[0])) % 2 != 0 else 0.7, \
    150.0)

def createCamera(pos, lookat):
    forward = normalize(np.asarray(lookat) - pos)
    down = vec([0,-1,0])
    right = 1.5*normalize(cross(forward, down))
    up = 1.5*normalize(cross(forward, right))
    return Camera(pos,forward,up,right)

def intersect(thing, ray):
    if isinstance(thing, Plane):
        denom = dot(thing.norm, ray.dir)
        if denom > 0:
            return None
        else:
            d = (dot(thing.norm, ray.start) + thing.offset) / (0-denom)
            return ISect(thing, ray, d)
    elif isinstance(thing, Sphere):
        eo = thing.center - ray.start
        v = dot(eo, ray.dir)
        if v > 0:
            disc = thing.radius*thing.radius - (dot(eo,eo) - v*v)
            dist = 0 if disc < 0 else v - sqrt(disc)
            if dist == 0:
                return None
            else:
                return ISect(thing,ray,dist)
        else:
            return None
    else:
        assert False, "Unknown thing."

def normal(thing, pos):
    if isinstance(thing, Plane):
        return thing.norm
    elif isinstance(thing, Sphere):
        return normalize(pos - thing.center)
    else:
        assert False, "Unknown thing."

Viewport = namedtuple("Viewport", "width height")

def recenterX(view,x):
    return (x - view.width / 2) / (2*view.width)

def recenterY(view,y):
    return -(y - view.height/2) / (2*view.height)

def getPoint(view,camera,x,y):
    return normalize(camera.forward+ \
        recenterX(view,x)*camera.right+ \
        recenterY(view,y)*camera.up)

def getNaturalColor(thing, pos, n, rd, scene):
    ret = vec([0,0,0])
    for light in scene.lights:
        ldis = light.pos - pos
        livec = normalize(ldis)
        neatIsect = testRay(Ray(pos,livec), scene)
        isInShadow = not ((neatIsect > norm(ldis)) or neatIsect == 0)
        if not isInShadow:
            illum = dot(livec, n)
            lcolor = illum*light.color if illum > 0 else vec([0,0,0])
            specular = dot(livec, normalize(rd))
            scolor = (specular**thing.surface.roughness)*light.color if specular > 0 else vec([0,0,0])
            ret = ret + thing.surface.diffuse(pos)*lcolor+thing.surface.specular(pos)*scolor
    return ret

def getReflectionColor(thing, pos, n, rd, scene, depth):
    return thing.surface.reflect(pos)*traceRay(Ray(pos,rd), scene, depth+1)

maxDepth = 5

def shade(isect, scene, depth):
    d = isect.ray.dir
    pos = isect.dist*isect.ray.dir + isect.ray.start
    n = normal(isect.thing, pos)
    reflectDir = d - 2*dot(n,d)*n
    ret = defaultColor + getNaturalColor(isect.thing, pos, n, reflectDir, scene)
    if depth >= maxDepth:
        return ret + vec([0.5,0.5,0.5])
    return ret + getReflectionColor(isect.thing, pos + (0.001*reflectDir), n, reflectDir, scene, depth)

def intersections(ray, scene):
    return sorted(filter(None, map((lambda t: intersect(t,ray)), scene.things)), key=lambda i: i.dist)

def testRay(ray, scene):
    for isect in intersections(ray, scene):
        return isect.dist
    return 0

def traceRay(ray, scene, depth):
    for isect in intersections(ray, scene):
        return shade(isect, scene, depth)
    return background

def render(view, scene):
    bitmap = np.zeros((view.width, view.height, 3), np.float64)
    for y in range(view.height):
        for x in range(view.width):
            c = traceRay(Ray(scene.camera.pos, getPoint(view,scene.camera,x,y)), scene, 0)
            bitmap[x,y,:] = c
    return np.clip(bitmap*255, 0, 255).astype(np.uint8)

def writePPM(filename, bitmap):
    w = bitmap.shape[0]
    h = bitmap.shape[1]
    header = f"P3 {w} {h} 255\n\n"
    with open(filename, "w") as io:
        io.write(header)
        for y in range(h):
            for x in range(w):
                io.write(f"{bitmap[x,y,0]} {bitmap[x,y,1]} {bitmap[x,y,2]} ")
            io.write("\n")

def simpleSurface(diffuse, reflect, roughness):
    return Surface(lambda p: diffuse, lambda p: vec([0.5,0.5,0.5]), lambda p: reflect, 200.0*roughness)

def parseFile(file):
    view = Viewport(600,600)
    things = []
    lights = []
    camera = None
    with open(file, "r") as io:
        for rawl in io:
            l = rawl.split("#")
            if len(l) == 0:
                continue            
            ws = list(filter(lambda x: x != "", l[0].split(" ")))
            if len(ws) != 0:
                if ws[0] == "#":
                    pass
                elif ws[0] == "sphere":
                    assert len(ws) == 1+9,f"sphere requires 9 values, saw {len(ws)-1}:\n\t{ws}"
                    vs = list(map(float, ws[1:11]))
                    things.append(Sphere(vec(vs[0:3]), vs[3], simpleSurface(vec(vs[4:7]),vs[7],vs[8])))
                elif ws[0] == "light":
                    assert len(ws) == 1+6,f"light requires 6 values, saw {len(ws)-1}:\n\t{ws}"
                    vs = list(map(float, ws[1:7]))
                    n = max(vs[3:6])
                    n = 1 if n < 1 else n
                    lights.append(Light(vec(vs[0:3]), vec(vs[3:6])/n))
                elif ws[0] == "camera":
                    assert len(ws) == 1+6,f"camera requires 6 values, saw {len(ws)-1}:\n\t{ws}"
                    vs = list(map(float, ws[1:7]))
                    camera = createCamera(vec(vs[0:3]), vec(vs[3:6]))
                elif ws[0] == "view":
                    assert len(ws) == 1+2,f"view requires 2 values, saw {len(ws)-1}:\n\t{ws}"
                    vs = list(map(float, ws[1:3]))
                    view = Viewport(vs[0], vs[1])
    assert camera != None, "Must have a camera defined in the scene."
    return (view, Scene(things, lights, camera))

demoScene = Scene(
    [ Plane(vec([0,1,0]), 0, checkerboard),
      Sphere(vec([0,1,0]), 1, shiny),
      Sphere(vec([-1,0.5,1.5]), 0.5, shiny)
    ],
    [ Light(vec([ -2,2.5,   0]), vec([.49,.07,.07 ])),
      Light(vec([1.5,2.5, 1.5]), vec([.07,.07,.49 ])),
      Light(vec([1.5,2.5,-1.5]), vec([.07,.49,.071])),
      Light(vec([  0,3.5,   0]), vec([.21,.21,.35 ]))
    ],
    createCamera(vec([3,2,4]),vec([-1,0.5,0]))
)

if len(sys.argv) == 3:
    print(f"Reading {sys.argv[1]}\nOutput {sys.argv[2]}")
    r = parseFile(sys.argv[1])
    if r != None:
        view,scene = r
        print(f"Rendering {view.width}x{view.height} scene")
        print(f"Things: {len(scene.things)}")
        print(f"Lights: {len(scene.lights)}")
        s = time.time() 
        bmp = render(view, scene)
        e = time.time()
        print(f"Done {e - s} seconds")
        writePPM(sys.argv[2],bmp)
elif len(sys.argv) == 2 and sys.argv[1] == "--demo":
    bmp = render(Viewport(400,400), demoScene)
    writePPM("demo.ppm", bmp)
else:
    print(f"Usage: {sys.argv[0]} [scene file] [output ppm]")
