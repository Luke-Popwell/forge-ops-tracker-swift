@testable import ForgeOpsTracker
import XCTest

final class TraceTests: XCTestCase {
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

    private func configure(threshold: TimeInterval, tracing: Bool = true) {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.releaseVersion = "a1b2c3d"
            config.crashReportsDirectory = tempDirectory
            config.traceCaptureThreshold = threshold
            config.trackTracing = tracing
        }
    }

    private func deliveredTrace() throws -> [String: Any] {
        XCTAssertEqual(server.allRequests().count, 1)
        let body = try XCTUnwrap(server.allRequests().last?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func span(_ name: String, in trace: [String: Any]) -> [String: Any]? {
        (trace["spans"] as? [[String: Any]])?.first { $0["name"] as? String == name }
    }

    func testASlowTraceIsDeliveredToSpansWithNestedSpansAndTheWireShape() throws {
        configure(threshold: 0.01)

        ForgeOpsTracker.trace("load home screen") { trace in
            trace.measureSpan("fetch feed", kind: "http", data: ["status": 200]) {
                trace.recordSpan("SELECT feed", kind: "database", startedAt: Date(timeIntervalSince1970: 1_700_000_000.123), durationMs: 3)
                Thread.sleep(forTimeInterval: 0.03)
            }
            trace.recordSpan("sibling", startedAt: Date(), durationMs: 1)
        }
        ForgeOpsTracker.flushSpans()

        XCTAssertEqual(server.allRequests().last?.path, "/api/v1/spans")
        let trace = try deliveredTrace()
        XCTAssertEqual((trace["trace_id"] as? String)?.count, 32)
        let root = try XCTUnwrap(span("load home screen", in: trace))
        let fetch = try XCTUnwrap(span("fetch feed", in: trace))
        XCTAssertTrue(root["parent_span_id"] is NSNull)
        XCTAssertEqual(root["kind"] as? String, "controller")
        XCTAssertEqual((root["span_id"] as? String)?.count, 16)
        XCTAssertEqual(fetch["parent_span_id"] as? String, root["span_id"] as? String)
        XCTAssertEqual(span("SELECT feed", in: trace)?["parent_span_id"] as? String, fetch["span_id"] as? String)
        XCTAssertEqual(span("sibling", in: trace)?["parent_span_id"] as? String, root["span_id"] as? String)
        XCTAssertEqual(span("SELECT feed", in: trace)?["started_at"] as? String, "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(fetch["environment"] as? String, "production")
        XCTAssertEqual(fetch["release"] as? String, "a1b2c3d")
        XCTAssertEqual((fetch["data"] as? [String: Any])?["status"] as? Int, 200)
    }

    func testAnUnknownKindIsSentAsOtherSinceTheServerWouldRejectTheWholeTrace() throws {
        configure(threshold: 0.01)

        ForgeOpsTracker.trace("t") { trace in
            trace.recordSpan("q", kind: "db", startedAt: Date(), durationMs: 1)
            trace.recordSpan("r", kind: "database", startedAt: Date(), durationMs: 1)
            Thread.sleep(forTimeInterval: 0.03)
        }
        ForgeOpsTracker.flushSpans()

        let trace = try deliveredTrace()
        XCTAssertEqual(span("q", in: trace)?["kind"] as? String, "other")
        XCTAssertEqual(span("r", in: trace)?["kind"] as? String, "database")
    }

    func testABodyThatThrowsStillRecordsItsSpanSendsTheTraceAndRethrowsUnchanged() throws {
        configure(threshold: 0.01)

        XCTAssertThrowsError(try ForgeOpsTracker.trace("boom") { trace in
            try trace.measureSpan("bad") {
                Thread.sleep(forTimeInterval: 0.03)
                throw Boom()
            }
        }) { XCTAssertTrue($0 is Boom) }
        ForgeOpsTracker.flushSpans()

        XCTAssertNotNil(span("bad", in: try deliveredTrace()))
    }

    func testAFastTraceSendsNothing() {
        configure(threshold: 60)

        ForgeOpsTracker.trace("fast") { trace in
            trace.recordSpan("q", kind: "database", startedAt: Date(), durationMs: 1)
        }
        ForgeOpsTracker.flushSpans()

        XCTAssertEqual(server.allRequests().count, 0)
    }

    func testTrackTracingOffOrReportingDisabledStartsNoTraceAndTheOptionalFormsStillRunTheBody() {
        configure(threshold: 0.01, tracing: false)
        XCTAssertNil(ForgeOpsTracker.startTrace("x"))
        var ran = false
        ForgeOpsTracker.trace("x") { trace in
            XCTAssertNil(trace)
            ran = trace.measureSpan("y") {
                Thread.sleep(forTimeInterval: 0.03)
                return true
            }
            trace.recordSpan("z", startedAt: Date(), durationMs: 1)
            trace.finish()
        }
        XCTAssertTrue(ran)

        ForgeOpsTracker.configure { config in
            config.trackTracing = true
            config.environment = "development"
        }
        XCTAssertNil(ForgeOpsTracker.startTrace("x"))
        ForgeOpsTracker.flushSpans()
        XCTAssertEqual(server.allRequests().count, 0)
    }

    func testASpanRecordedFromAnotherThreadParentsUnderTheRootNotTheOpenSpanOnThisOne() throws {
        configure(threshold: 0.01)

        ForgeOpsTracker.trace("t") { trace in
            trace.measureSpan("outer") {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    trace.recordSpan("background", kind: "job", startedAt: Date(), durationMs: 1)
                    done.signal()
                }
                done.wait()
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        ForgeOpsTracker.flushSpans()

        let trace = try deliveredTrace()
        XCTAssertEqual(span("background", in: trace)?["parent_span_id"] as? String, span("t", in: trace)?["span_id"] as? String)
    }

    func testFinishIsIdempotentAndSpansAfterItAreDropped() throws {
        configure(threshold: 0.01)

        let trace = ForgeOpsTracker.startTrace("t")
        Thread.sleep(forTimeInterval: 0.03)
        trace.finish()
        trace.finish()
        trace.recordSpan("late", startedAt: Date(), durationMs: 1)
        trace.finish()
        ForgeOpsTracker.flushSpans()

        XCTAssertEqual(server.allRequests().count, 1)
        XCTAssertNil(span("late", in: try deliveredTrace()))
    }

    func testATraceHoldsAtMost500SpansIncludingTheRoot() {
        let config = Configuration()
        config.dsn = "http://key@127.0.0.1:1/api/v1/events"
        config.traceCaptureThreshold = 0
        var delivered: [String: Any]?
        let trace = Trace(name: "root", configuration: config) { delivered = $0 }
        for _ in 0 ..< 700 {
            trace.recordSpan("q", kind: "database", startedAt: Date(), durationMs: 1)
        }
        trace.finish()

        XCTAssertEqual((delivered?["spans"] as? [Any])?.count, 500)
    }

    func testSpansURLSwapsTheTrailingEventsSegment() {
        let config = Configuration()
        config.dsn = "https://key@tracker.example.com/api/v1/events"
        XCTAssertEqual(config.spansURL?.absoluteString, "https://tracker.example.com/api/v1/spans")
    }
}
