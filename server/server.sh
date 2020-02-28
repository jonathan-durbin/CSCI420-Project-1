#!/bin/bash

echo "Starting server."
JULIA_NUM_THREADS=5 ~/julia-1.3.1/bin/julia server.jl
