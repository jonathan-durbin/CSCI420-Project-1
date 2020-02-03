using System;
using System.Diagnostics;
using RayTracer;

namespace DistributedRay
{
    class Program
    {
        static void Main(string[] args)
        {
            if (args.Length == 2)
            {
                var w = new Stopwatch();
                Console.WriteLine("Starting.");
                w.Start();
                RayTracerApp.Run(args[0], args[1]);
                w.Stop();
                Console.WriteLine($"Done.  Time: {w.Elapsed}.");
            }
            else if (args.Length == 1 && args[0] == "--demo")
            {
                RayTracerApp.RunDemo();
            }
            else
            {
                Console.WriteLine("Usage: RayTracer [input.scene] [output.ppm]");
                Environment.Exit(-1);
            }
            
        }
    }
}
