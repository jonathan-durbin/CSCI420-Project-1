using Sockets

server = @async begin
    servsock = UDPSocket()
    bind(servsock, ip"127.0.0.1", 3000)
    while true
        r = recv(servsock)
        println(r)
    end
end
