using Sockets

#=
create a bucket of work that needs to be filled.
divide up the work between servers defined in SERVER_LIST
send work to each server
while waiting, do own work
if data is sent back, add it to the final image
=#

sock = UDPSocket()
bind(sock, ip"127.0.0.1", 3001)

# job = "work"
SERVER_LIST = [
    (ipaddr = ip"127.0.0.1", port = 3000)
]

FILE = "client/default.scene"
NUMBYTES = 500

# read(f, 30) -> read 30 bytes of f

open(FILE, "r") do io
    # converts the UInt64 hash to an array of UInt8 partial hashes.
    h = reinterpret(UInt8, [hash(read(io, String))])

    # the server will have to know to connect the first 8 bytes of file-sending messages to form the file hash
    for server in SERVER_LIST
        seekstart(io)
        bs = read(io, NUMBYTES)
        while length(bs) > 0
            # send 500-ish byte packets, adding the file hash (8 bytes) to the beginning of each message
            send(sock, server[:ipaddr], server[:port], cat(h, bs, dims=1))
            bs = read(io, NUMBYTES)
        end
    end
end

close(sock)
