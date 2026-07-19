import Foundation

enum MessageType: UInt32 {
    case output   = 1
    case exitCode = 2
    case error    = 3
    case done     = 4
}

struct IPCMessage {
    let type: MessageType
    let data: Data
}

// MARK: - Server (Daemon side)

class IPCServer {
    let path: String
    private var sock: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String) {
        self.path = path
    }

    func start(handler: @escaping (Data, @escaping (Data) -> Void) -> Void) throws {
        unlink(path)

        sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw MslError("socket: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            strncpy(ptr, path, pathSize - 1)
        }

        let addrSize = MemoryLayout.size(ofValue: addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(addrSize))
            }
        }
        guard bound == 0 else { close(sock); throw MslError("bind: \(String(cString: strerror(errno)))") }

        listen(sock, 128)
        chmod(path, 0o600)

        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .main)
        source.setEventHandler { [weak self] in self?.handleAccept(handler: handler) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        if sock >= 0 { close(sock); sock = -1 }
        unlink(path)
    }

    private func handleAccept(handler: @escaping (Data, @escaping (Data) -> Void) -> Void) {
        let client = Darwin.accept(sock, nil, nil)
        guard client >= 0 else { return }

        let clientSource = DispatchSource.makeReadSource(fileDescriptor: client, queue: .main)
        let send: (Data) -> Void = { data in
            var remaining = data
            while !remaining.isEmpty {
                let n = write(client, (remaining as NSData).bytes, remaining.count)
                if n <= 0 { break }
                remaining = remaining.dropFirst(n)
            }
        }

        var readBuf = [UInt8](repeating: 0, count: 65536)
        var accum = Data()

        clientSource.setEventHandler {
            let n = read(client, &readBuf, readBuf.count)
            if n <= 0 {
                clientSource.cancel()
                close(client)
                return
            }
            accum.append(readBuf, count: n)

    // Process complete frames (cap at 100MB to prevent OOM on malformed length)
            while accum.count >= 4 {
                let len = UInt32(bigEndian: accum.withUnsafeBytes { $0.load(as: UInt32.self) })
                guard len <= 100 * 1024 * 1024 else {
                    clientSource.cancel()
                    close(client)
                    return
                }
                let total = Int(4 + len)
                guard accum.count >= total else { break }

                let payload = accum.subdata(in: 4..<total)
                accum = accum.dropFirst(total)

                // Re-arm the source after each request (simple serial handling)
                handler(payload, send)
            }
        }
        clientSource.resume()
    }
}

// MARK: - Client (CLI side)

class IPCClient {
    let path: String

    init(path: String) {
        self.path = path
    }

    func send(request: Data, timeout: TimeInterval = 30) throws -> [IPCMessage] {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw MslError("socket: \(String(cString: strerror(errno)))") }
        defer { close(sock) }

        // Set send + receive timeouts on the socket so we don't hang forever
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        let tvSize = socklen_t(MemoryLayout.size(ofValue: tv))
        _ = withUnsafePointer(to: &tv) {
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, $0, tvSize)
        }
        _ = withUnsafePointer(to: &tv) {
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, $0, tvSize)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            strncpy(ptr, path, pathSize - 1)
        }

        let addrSize = MemoryLayout.size(ofValue: addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(addrSize))
            }
        }
        guard connected == 0 else {
            throw MslError("connect: \(String(cString: strerror(errno)))")
        }

        // Write framed request: 4-byte BE len + payload
        var len = UInt32(request.count).bigEndian
        var req = Data()
        withUnsafePointer(to: &len) { req.append(UnsafeBufferPointer(start: $0, count: 1)) }
        req.append(request)
        var remaining = req
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { write(sock, $0.baseAddress, remaining.count) }
            if n <= 0 { throw MslError("write: \(String(cString: strerror(errno)))") }
            remaining = remaining.dropFirst(n)
        }

        // Read all response frames with timeout
        var messages = [IPCMessage]()
        var buf = [UInt8](repeating: 0, count: 131072)
        var accum = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let n = read(sock, &buf, buf.count)
            if n > 0 {
                accum.append(buf, count: n)
            } else if n == 0 {
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if messages.isEmpty {
                        throw MslError("read timed out after \(Int(timeout))s")
                    }
                    break
                }
                throw MslError("read: \(String(cString: strerror(errno)))")
            }

            while true {
                guard accum.count >= 8 else { break }
                let typeRaw = accum.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(as: UInt32.self).bigEndian
                }
                let type = MessageType(rawValue: typeRaw) ?? .done
                let msgLen = accum.withUnsafeBytes { ptr in
                    ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self).bigEndian
                }
                let total = Int(8 + msgLen)
                guard accum.count >= total else { break }
                var msgData = Data(count: total - 8)
                _ = msgData.withUnsafeMutableBytes { dst in
                    accum.withUnsafeBytes { src in
                        memcpy(dst.baseAddress!, src.baseAddress! + 8, total - 8)
                    }
                }
                accum.removeFirst(total)
                messages.append(IPCMessage(type: type, data: msgData))
                if type == .done || type == .exitCode { return messages }
            }
        }

        if messages.isEmpty {
            throw MslError("read timed out after \(Int(timeout))s")
        }
        return messages
    }
}
