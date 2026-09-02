import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// A minimal, real localhost HTTP server -- used only where the code under test genuinely can't
/// take a stubbed URLProtocol (the public `ForgeOpsTracker` facade builds its own `Client`
/// internally with no injection point, unlike `Client`/`Reporter` in the other test files, the
/// same reason this repo's own Objective-C client's `FOTTestHTTPServer.m` exists). A direct Swift
/// port of that file: same raw-socket approach, same request-recording shape.
final class TestHTTPServer {
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()
    private var requests: [(method: String, path: String, headers: [String: String], body: String)] = []

    func start() {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        addr.sin_port = 0 // ask the OS for a free port

        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                _ = bind(listenFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(listenFD, 16)

        var bound = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                _ = getsockname(listenFD, sockaddrPtr, &boundLen)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)

        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    func allRequests() -> [(method: String, path: String, headers: [String: String], body: String)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func acceptLoop() {
        while running {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(listenFD, &readSet)
            var timeout = timeval(tv_sec: 0, tv_usec: 100000)

            let ready = select(listenFD + 1, &readSet, nil, nil, &timeout)
            if ready <= 0 || !running {
                continue
            }

            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { continue }
            handleClient(clientFD)
            close(clientFD)
        }
    }

    private func handleClient(_ clientFD: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        var headerEndRange: Range<Data.Index>?

        while headerEndRange == nil {
            let n = read(clientFD, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0 ..< n])
            headerEndRange = buffer.range(of: terminator)
        }
        guard let headerEndRange else { return }

        let headerText = String(data: buffer.subdata(in: buffer.startIndex ..< headerEndRange.lowerBound), encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").components(separatedBy: " ")
        let method = requestLine.count > 0 ? requestLine[0] : ""
        let path = requestLine.count > 1 ? requestLine[1] : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonRange = line.range(of: ": ") else { continue }
            headers[String(line[line.startIndex ..< colonRange.lowerBound])] = String(line[colonRange.upperBound...])
        }

        let contentLength = Int(headers["Content-Length"] ?? "0") ?? 0
        let bodyStart = headerEndRange.upperBound
        while buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart) < contentLength {
            let n = read(clientFD, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0 ..< n])
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: min(contentLength, buffer.distance(from: bodyStart, to: buffer.endIndex)))
        let body = String(data: buffer.subdata(in: bodyStart ..< bodyEnd), encoding: .utf8) ?? ""

        lock.lock()
        requests.append((method: method, path: path, headers: headers, body: body))
        lock.unlock()

        let status = path == "/unauthorized" ? "401 Unauthorized" : "202 Accepted"
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let responseData = Data(response.utf8)
        responseData.withUnsafeBytes { ptr in
            _ = write(clientFD, ptr.baseAddress, responseData.count)
        }
    }
}

private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int32(fd % 32)
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bitsPtr in
            bitsPtr[intOffset] |= mask
        }
    }
}
