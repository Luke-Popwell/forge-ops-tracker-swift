import Foundation

/// A `URLProtocol` stub for `Client` tests: avoids a real network call or a hand-rolled TCP
/// server, using Foundation's own URL-loading test seam instead (`Client.init(protocolClasses:)`
/// exists purely so tests can register this). Plays the same role
/// `sdks/objc/Tests/FOTTestHTTPServer.m` plays for this repo's own Objective-C client.
final class StubURLProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let bodyString: String?
    }

    static var statusCode = 200
    static var recorded: [Recorded] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData: Data? = request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? request.httpBody

        StubURLProtocol.recorded.append(
            Recorded(request: request, bodyString: bodyData.flatMap { String(data: $0, encoding: .utf8) })
        )

        let response = HTTPURLResponse(url: request.url!, statusCode: StubURLProtocol.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
