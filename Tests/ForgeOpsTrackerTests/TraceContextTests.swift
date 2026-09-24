import CFOTTestSupport
@testable import ForgeOpsTracker
import XCTest

final class TraceContextTests: XCTestCase {
    private var server: TestHTTPServer!
    private var tempDirectory: String!

    private struct Boom: Error {}

    override func setUp() {
        super.setUp()
        ForgeOpsTracker._resetForTesting()
        tempDirectory = NSTemporaryDirectory() + UUID().uuidString
        server = TestHTTPServer()
        server.start()
        Thread.sleep(forTimeInterval: 0.05)
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: tempDirectory)
        ForgeOpsTracker._resetForTesting()
        super.tearDown()
    }

    private func configureReporting() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
            config.traceCaptureThreshold = 60 // never deliver spans here: only error events reach the server
        }
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func deliveredEvent() throws -> [String: Any] {
        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        let body = try XCTUnwrap(server.allRequests().last?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    // A trace built directly, with delivery captured in memory and no threshold, so every test
    // below sees exactly what would go on the wire.
    private func makeTrace(_ configure: (Configuration) -> Void = { _ in }) -> (Trace, () -> [String: Any]?) {
        let config = Configuration()
        config.dsn = "http://key@127.0.0.1:1/api/v1/events"
        config.traceCaptureThreshold = 0
        configure(config)
        var delivered: [String: Any]?
        let trace = Trace(name: "checkout", configuration: config) { delivered = $0 }
        return (trace, { delivered })
    }

    private func spans(_ payload: [String: Any]?) -> [[String: Any]] {
        (payload?["spans"] as? [[String: Any]]) ?? []
    }

    private func span(_ name: String, in payload: [String: Any]?) -> [String: Any]? {
        spans(payload).first { $0["name"] as? String == name }
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.example.com/orders")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func orderRequest(_ url: String = "https://api.example.com/orders") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        return request
    }

    func testTraceAndSpanIdsAreW3CFormatLowercaseHexAndNeverAllZeros() throws {
        let traceId = try NSRegularExpression(pattern: "^[0-9a-f]{32}$")
        let spanId = try NSRegularExpression(pattern: "^[0-9a-f]{16}$")
        func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }

        for _ in 0 ..< 200 {
            let generatedTrace = Trace.generateTraceId()
            let generatedSpan = Trace.generateSpanId()
            XCTAssertTrue(matches(traceId, generatedTrace))
            XCTAssertTrue(matches(spanId, generatedSpan))
            XCTAssertNotEqual(generatedTrace, String(repeating: "0", count: 32))
            XCTAssertNotEqual(generatedSpan, String(repeating: "0", count: 16))
        }

        let (trace, delivered) = makeTrace()
        trace.recordSpan("q", startedAt: Date(), durationMs: 1)
        trace.finish()
        XCTAssertTrue(matches(traceId, trace.traceId))
        XCTAssertEqual(delivered()?["trace_id"] as? String, trace.traceId)
        for recorded in spans(delivered()) {
            XCTAssertTrue(matches(spanId, try XCTUnwrap(recorded["span_id"] as? String)))
        }
    }

    func testStartRequestSpanAddsATraceparentWhoseParentIdIsTheRecordedHttpSpan() throws {
        let (trace, delivered) = makeTrace()

        let requestSpan = trace.startRequestSpan(orderRequest())
        let spanId = try XCTUnwrap(requestSpan.spanId)
        let header = "00-\(trace.traceId)-\(spanId)-01"
        XCTAssertEqual(requestSpan.request.value(forHTTPHeaderField: "traceparent"), header)
        XCTAssertEqual(requestSpan.traceparent, header)
        XCTAssertEqual(requestSpan.request.url?.absoluteString, "https://api.example.com/orders")
        requestSpan.finish(response: response(201))
        requestSpan.finish(response: response(500)) // idempotent
        trace.finish()

        let root = try XCTUnwrap(span("checkout", in: delivered()))
        let http = try XCTUnwrap(span("POST api.example.com", in: delivered()))
        XCTAssertEqual(spans(delivered()).count, 2)
        XCTAssertEqual(http["span_id"] as? String, spanId)
        XCTAssertEqual(http["parent_span_id"] as? String, root["span_id"] as? String)
        XCTAssertEqual(http["kind"] as? String, "http")
        XCTAssertEqual((http["data"] as? [String: Any])?["status"] as? Int, 201)
    }

    func testMeasureRequestSendsTheHeaderRecordsTheStatusAndReturnsTheBodysValue() throws {
        let (trace, delivered) = makeTrace()
        var sentHeader: String?

        let (data, _) = trace.measureRequest(orderRequest(), name: "create order") { request -> (Data, URLResponse) in
            sentHeader = request.value(forHTTPHeaderField: "traceparent")
            return (Data("ok".utf8), response(200))
        }
        trace.finish()

        XCTAssertEqual(data, Data("ok".utf8))
        let http = try XCTUnwrap(span("create order", in: delivered()))
        XCTAssertEqual(sentHeader, "00-\(trace.traceId)-\(try XCTUnwrap(http["span_id"] as? String))-01")
        XCTAssertEqual((http["data"] as? [String: Any])?["status"] as? Int, 200)
    }

    func testMeasureRequestRecordsTheSpanWithoutAStatusWhenTheBodyThrowsAndRethrowsUnchanged() throws {
        let (trace, delivered) = makeTrace()

        XCTAssertThrowsError(try trace.measureRequest(orderRequest()) { _ -> Int in throw Boom() }) { XCTAssertTrue($0 is Boom) }
        trace.finish()

        let http = try XCTUnwrap(span("POST api.example.com", in: delivered()))
        XCTAssertNil((http["data"] as? [String: Any])?["status"])
    }

    func testTheAsyncMeasureRequestSendsTheHeaderAndRecordsTheStatus() async throws {
        let (trace, delivered) = makeTrace()

        let header = try await trace.measureRequest(orderRequest()) { request -> (String?, HTTPURLResponse) in
            try await Task.sleep(nanoseconds: 1_000_000)
            return (request.value(forHTTPHeaderField: "traceparent"), response(502))
        }.0
        trace.finish()

        let http = try XCTUnwrap(span("POST api.example.com", in: delivered()))
        XCTAssertEqual(header, "00-\(trace.traceId)-\(try XCTUnwrap(http["span_id"] as? String))-01")
        // A (String?, HTTPURLResponse) pair is not one of URLSession's own shapes, so no status.
        XCTAssertNil((http["data"] as? [String: Any])?["status"])

        let (trace2, delivered2) = makeTrace()
        _ = await trace2.measureRequest(orderRequest()) { _ async -> (Data, URLResponse) in (Data(), response(503)) }
        trace2.finish()
        XCTAssertEqual((span("POST api.example.com", in: delivered2())?["data"] as? [String: Any])?["status"] as? Int, 503)
    }

    func testARequestSpanParentsUnderTheSpanOpenOnThisThread() throws {
        let (trace, delivered) = makeTrace()

        trace.measureSpan("submit order") {
            trace.measureRequest(orderRequest()) { _ in response(200) }
        }
        trace.finish()

        let submit = try XCTUnwrap(span("submit order", in: delivered()))
        XCTAssertEqual(span("POST api.example.com", in: delivered())?["parent_span_id"] as? String, submit["span_id"] as? String)
    }

    func testPropagateTracesOffStillRecordsTheSpanButAddsNoHeader() throws {
        let (trace, delivered) = makeTrace { $0.propagateTraces = false }

        let requestSpan = trace.startRequestSpan(orderRequest())
        XCTAssertNil(requestSpan.request.value(forHTTPHeaderField: "traceparent"))
        XCTAssertNil(requestSpan.traceparent)
        requestSpan.finish()
        trace.finish()

        XCTAssertNotNil(span("POST api.example.com", in: delivered()))
    }

    func testOnlyTargetedHostsGetTheHeader() {
        let (trace, _) = makeTrace { $0.tracePropagationTargets = ["example.com", .pattern(#"\.internal$"#)] }

        XCTAssertNotNil(trace.startRequestSpan(orderRequest("https://api.example.com/x")).traceparent)
        XCTAssertNotNil(trace.startRequestSpan(orderRequest("https://orders.internal/x")).traceparent)
        XCTAssertNil(trace.startRequestSpan(orderRequest("https://badexample.com/x")).traceparent)
        XCTAssertNil(trace.startRequestSpan(orderRequest("https://payments.thirdparty.io/x")).traceparent)
    }

    func testATraceparentTheRequestAlreadyHasIsLeftAlone() {
        let (trace, _) = makeTrace()
        var request = orderRequest()
        request.setValue("00-11111111111111111111111111111111-2222222222222222-01", forHTTPHeaderField: "traceparent")

        let requestSpan = trace.startRequestSpan(request)
        XCTAssertEqual(requestSpan.request.value(forHTTPHeaderField: "traceparent"), "00-11111111111111111111111111111111-2222222222222222-01")
        XCTAssertNil(requestSpan.traceparent)
    }

    func testWithNoTraceTheRequestIsSentUnchangedAndNothingIsRecorded() throws {
        let trace: Trace? = nil
        let request = orderRequest()

        let requestSpan = trace.startRequestSpan(request)
        XCTAssertEqual(requestSpan.request, request)
        XCTAssertNil(requestSpan.spanId)
        XCTAssertNil(requestSpan.traceparent)
        requestSpan.finish(response: response(200))

        let sent = trace.measureRequest(request) { $0 }
        XCTAssertEqual(sent, request)
        XCTAssertThrowsError(try trace.measureRequest(request) { _ in throw Boom() }) { XCTAssertTrue($0 is Boom) }
    }

    func testAnErrorCapturedWithAnExplicitTraceCarriesItsTraceId() throws {
        configureReporting()
        let trace = ForgeOpsTracker.startTrace("checkout")

        ForgeOpsTracker.capture(error: Boom(), trace: trace)

        XCTAssertEqual(try deliveredEvent()["trace_id"] as? String, try XCTUnwrap(trace?.traceId))
    }

    func testAnErrorCapturedInsideATraceBodyCarriesItsTraceIdWithoutPassingIt() throws {
        configureReporting()
        var traceId: String?

        ForgeOpsTracker.trace("checkout") { trace in
            traceId = trace?.traceId
            trace.measureSpan("charge") {
                ForgeOpsTracker.capture(error: Boom())
            }
        }

        XCTAssertEqual(try deliveredEvent()["trace_id"] as? String, try XCTUnwrap(traceId))
        XCTAssertNil(Trace.current)
    }

    func testAnErrorCapturedInsideMeasureRequestOnAStartedTraceCarriesItsTraceId() throws {
        configureReporting()
        let trace = ForgeOpsTracker.startTrace("checkout")

        trace.measureRequest(orderRequest()) { _ in
            ForgeOpsTracker.capture(error: Boom())
        }

        XCTAssertEqual(try deliveredEvent()["trace_id"] as? String, try XCTUnwrap(trace?.traceId))
    }

    func testCaptureExceptionWithATraceCarriesItsTraceId() throws {
        configureReporting()
        let trace = ForgeOpsTracker.startTrace("checkout")

        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("TestException", "boom"), trace: trace)

        XCTAssertEqual(try deliveredEvent()["trace_id"] as? String, try XCTUnwrap(trace?.traceId))
    }

    func testAnErrorCapturedWithNoTraceHasNoTraceId() throws {
        configureReporting()
        let trace = ForgeOpsTracker.startTrace("checkout") // started, but neither passed nor current
        trace.finish()

        ForgeOpsTracker.capture(error: Boom())

        XCTAssertNil(try deliveredEvent()["trace_id"])
    }

    func testTheTraceIdIsAddedAfterPiiScrubbingAndOnlyWhenGiven() {
        let config = Configuration()
        let traceId = Trace.generateTraceId()

        let linked = EventBuilder.buildEvent(error: Boom(), configuration: config, context: nil, traceId: traceId)
        let unlinked = EventBuilder.buildEvent(error: Boom(), configuration: config, context: nil)

        XCTAssertEqual(linked["trace_id"] as? String, traceId)
        XCTAssertNil(unlinked["trace_id"])
    }
}
