import scala.language.implicitConversions
import scala.util.ChainingOps
import scala.math.Ordering.Double.IeeeOrdering
import scala.io.Source
import java.io._

case class Vec(x : Double, y : Double, z : Double) {
    def +(v:Vec) = Vec(x+v.x, y+v.y, z+v.z)
    def -(v:Vec) = Vec(x-v.x, y-v.y, z-v.z)
    def *(d:Double) = Vec(d*x, d*y, d*z)
    def /(d:Double) = Vec(x/d, y/d, z/d)
    def **(v:Vec) = Vec(x*v.x,y*v.y,z*v.z)

    def norm() = Math.sqrt(x*x + y*y + z*z)
    def normalize() : Vec = { val n = norm ; return this/n }
}

val zeroV = Vec(0,0,0)

case class Scalar(x : Double) {
    def *(v:Vec) = v*x
}

implicit def doubleToScalar(d : Double) : Scalar = Scalar(d)

def cross(a : Vec, b : Vec) : Vec = Vec(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
def dot(a : Vec, b : Vec) : Double = a.x*b.x+a.y*b.y+a.z*b.z

case class Ray(start : Vec, dir : Vec)

case class Surface(
    diffuse : Vec => Vec,
    specular : Vec => Vec,
    reflect : Vec => Double,
    roughness : Double
)

val shiny = new Surface(_ => Vec(1,1,1), _ => Vec(0.5,0.5,0.5), _ => 0.6, 50.0)
val checkerboard = new Surface(
    p => if ((p.z.floor + p.x.floor) % 2 != 0) Vec(1,1,1) else zeroV,
    _ => Vec(1,1,1),
    p => if ((p.z.floor + p.x.floor) % 2 != 0) 0.1 else 0.7,
    150.0
) 

case class Camera(
    val pos : Vec,
    val forward : Vec,
    val up : Vec,
    val right : Vec
)

def createCamera(pos : Vec, lookat : Vec) : Camera = {
    val forward = (lookat - pos).normalize
    val down = Vec(0,-1,0)
    val right = 1.5*cross(forward, down).normalize
    val up = 1.5*cross(forward, right).normalize
    return Camera(pos, forward, up, right)
}

case class Light(
    pos : Vec,
    color : Vec
)

trait Thing { def surface : Surface }

case class Plane(
    surface : Surface,
    norm : Vec,
    offset : Double
) extends Thing

case class Sphere(
    surface : Surface,
    center : Vec,
    radius : Double
) extends Thing

case class Scene(
    things : List[Thing],
    lights : List[Light],
    camera : Camera
)

case class ISect(
    thing : Thing,
    ray   : Ray,
    dist  : Double
)

def intersect(thing : Thing, ray : Ray) : Option[ISect] = {
    thing match {
        case Plane(_,norm,offset) => {
            val denom = dot(norm, ray.dir)
            if (denom > 0)
                return None
            val d = (dot(norm, ray.start) + offset) / (-denom)
            return Some(ISect(thing,ray,d))
        }
        case Sphere(_,center,radius) => {
            val eo = center - ray.start
            val v = dot(eo, ray.dir)
            if (v > 0) {
                val disc = radius*radius - (dot(eo,eo) - v*v)
                val dist = if (disc < 0) 0 else v - Math.sqrt(disc)
                if (dist == 0)
                    return None
                return Some(ISect(thing,ray,dist))
            }
            return None
        }
    }
}

def normal(thing : Thing, pos : Vec) : Vec = 
    thing match {
        case Plane(_,norm,_) => norm
        case Sphere(_,center,_) => (pos - center).normalize
    }

case class Viewport(
    width : Int,
    height : Int
) {
    def recenterX(x : Double) : Double = (x - width / 2) / (2*width)
    def recenterY(y : Double) : Double = -(y - height / 2) / (2*height)
    def getPoint(camera : Camera, x : Double, y : Double) : Vec =
        (camera.forward
            + recenterX(x)*camera.right
            + recenterY(y)*camera.up).normalize 
}

def getNaturalColor(surface : Surface, pos : Vec, n : Vec, rd : Vec, scene : Scene) : Vec = {
    var ret = zeroV
    for (light <- scene.lights) {
        val ldis = light.pos - pos
        val livec = ldis.normalize
        val neatIsect = testRay(Ray(pos,livec), scene)
        val isInShadow = !((neatIsect > ldis.norm) || neatIsect == 0)
        if (!isInShadow) {
            val illum = dot(livec, n)
            val lcolor = if (illum > 0) (illum*light.color) else zeroV
            val specular = dot(livec, rd.normalize)
            val scolor = if (specular > 0) (Math.pow(specular, surface.roughness)*light.color) else zeroV
            ret = ret + (surface.diffuse(pos)**lcolor)+
                        (surface.specular(pos)**scolor)
        }
    }
    return ret
}

def getReflectionColor(surface : Surface, pos : Vec, n : Vec, rd : Vec, scene : Scene, depth : Int) : Vec =
    surface.reflect(pos)*traceRay(Ray(pos,rd), scene, depth+1)

val maxDepth = 5
val defaultColor = zeroV
val background = zeroV

def shade(isect : ISect, scene : Scene, depth : Int) : Vec = {
    val d = isect.ray.dir
    val pos = isect.dist*isect.ray.dir + isect.ray.start
    val n = normal(isect.thing, pos)
    val reflectDir = d - 2*dot(n,d)*n
    val ret = defaultColor + getNaturalColor(isect.thing.surface, pos, n, reflectDir, scene)
    if (depth >= maxDepth)
        return ret + Vec(0.5,0.5,0.5)
    return ret + getReflectionColor(isect.thing.surface, pos + (0.001*reflectDir), n, reflectDir, scene, depth)
}

def firstIntersection(ray : Ray, scene : Scene) : Option[ISect] = {
    val vs = scene.things.map(o => intersect(o,ray)
                ).flatten.sortBy(i => i.dist)
    vs match {
        case isect :: _ => Some(isect)
        case _          => None
    }
}

def testRay(ray : Ray, scene : Scene) : Double =
    firstIntersection(ray, scene) match {
        case None => 0
        case Some(isect) => isect.dist
    }

def traceRay(ray : Ray, scene : Scene, depth : Int) : Vec = 
    firstIntersection(ray, scene) match {
        case None => background
        case Some(isect) => shade(isect, scene, depth)
    }

def toInt(x : Double) : Int = Math.min(255, x*255).toInt

def render(view : Viewport, scene : Scene) : Array[Array[Array[Int]]] = {
    val bitmap = Array.ofDim[Int](view.height, view.width, 3)
    for (y <- 0 until view.height) {
        for (x <- 0 until view.width) {
            val c = traceRay(Ray(scene.camera.pos, view.getPoint(scene.camera, x, y)), scene, 0)
            bitmap(y)(x)(0) = toInt(c.x)
            bitmap(y)(x)(1) = toInt(c.y)
            bitmap(y)(x)(2) = toInt(c.z)
        }
    }
    return bitmap
}

def writePPM(filename : String, bitmap : Array[Array[Array[Int]]]) : Unit = {
    val h = bitmap.size
    val w = bitmap(0).size
    val file = new File(filename)
    val bw = new BufferedWriter(new FileWriter(file))
    bw.write(s"P3 $w $h 255\n\n")
    for (y <- 0 until h) {
        for (x <- 0 until w)
            bw.write(s"${bitmap(y)(x)(0)} ${bitmap(y)(x)(1)} ${bitmap(y)(x)(2)} ")
        bw.write("\n")        
    }
    bw.close()
}

val demoScene = Scene(
    List(
        Plane (checkerboard, Vec( 0,  1,  0),   0),
        Sphere(shiny,        Vec( 0,  1,  0),   1),
        Sphere(shiny,        Vec(-1,0.5,1.5), 0.5)
    ),
    List(
        Light(Vec( -2,2.5,   0), Vec(.49,.07,.07 )),
        Light(Vec(1.5,2.5, 1.5), Vec(.07,.07,.49 )),
        Light(Vec(1.5,2.5,-1.5), Vec(.07,.49,.071)),
        Light(Vec(  0,3.5,   0), Vec(.21,.21,.35 ))
    ),
    createCamera(Vec(3,2,4), Vec(-1,0.5,0))
)

def simpleSurface(diffuse : Vec, reflect : Double, roughness : Double) : Surface =
    Surface(_ => diffuse, _ => Vec(.5,.5,.5), _ => reflect, 200.0*roughness)

def parseFile(file : String) : Option[(Viewport, Scene)] = {
    var view = Viewport(600,600)
    var things = List[Thing]()
    var lights = List[Light]()
    var camera : Option[Camera] = None
    for (line <- Source.fromFile(file).getLines) {
        val l = line.split("#")(0).trim()
                    .split(" ").filter(_ != "")
        if (l.length > 0) {
            val vs = l.tail.map(_.toDouble)
            l(0) match {
                case "sphere" => things = Sphere(simpleSurface(Vec(vs(4),vs(5),vs(6)),vs(7),vs(8)),
                                                Vec(vs(0),vs(1),vs(2)), vs(3)) :: things
                case "light"  => val n = vs.slice(3,6).max
                                 val d = if (n < 1) 1 else n
                                 lights = Light(Vec(vs(0),vs(1),vs(2)), Vec(vs(3),vs(4),vs(5))/d) :: lights
                case "camera" => camera = Some(createCamera(Vec(vs(0),vs(1),vs(2)),Vec(vs(3),vs(4),vs(5))))
                case "view"   => view = Viewport(vs(0).toInt,vs(1).toInt)
            }
        }
    }
    camera.map(c => (view,Scene(things.reverse, lights.reverse, c)))
}

// http://biercoff.com/easily-measuring-code-execution-time-in-scala/
def time[R](block: => R): R = {
    val t0 = System.nanoTime()
    val result = block    // call-by-name
    val t1 = System.nanoTime()
    println("Elapsed time: " + (t1 - t0)*(1e-9) + " seconds")
    result
}

if (args.length == 1 && args(0) == "--demo") {
    val bmp = render(Viewport(400,400), demoScene)
    writePPM("demo.ppm", bmp)
} else if (args.length == 2) {
    println(s"Reading ${args(0)}")
    parseFile(args(0)) match {
        case None => println("Failed to find a camera.")
        case Some((v,s)) => {
            println(s"Rendering ${v.width}x${v.height} scene")
            println(s"Things: ${s.things.length}")
            println(s"Lights: ${s.lights.length}")
            val bmp = time { render(v,s) }
            writePPM(args(1), bmp)
            println(s"Wrote ${args(1)}")
        }
    }
} else {
    println("Usage: raytracer [scene file] [output ppm]")
}