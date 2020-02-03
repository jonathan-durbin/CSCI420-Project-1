using Sockets

clisock = UDPSocket()

bind(clisock, ip"127.0.0.1", 3001)

send(clisock, ip"127.0.0.1", 3000, "Client to server!")