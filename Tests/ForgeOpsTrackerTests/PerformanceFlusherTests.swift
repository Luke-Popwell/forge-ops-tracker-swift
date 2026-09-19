@testable import ForgeOpsTracker
import XCTest

final class PerformanceFlusherTests: XCTestCase {
    private var server: TestHTTPServer!
    private var flusher: PerformanceFlusher!

    override func setUp() {
        super.setUp()
        server = TestHTTPServer()
        server.start()
        Thread.sleep(forTimeInterval: 0.05)
    }

    override func tearDown() {
        flusher?.discard()
        server.stop()
        super.tearDown()
    }

    private func configuration(path: String = "/api/v1/events") -> Configuration {
        let config = Configuration()
        config.dsn = "http://key@127.0.0.1:\(server.port)\(path)"
        config.environment = "production"
        config.performanceFlushInterval = 3600 // tests flush by hand unless they say otherwise
        config.timeout = 2
        return config
    }

    private func makeFlusher(_ config: Configuration) -> PerformanceFlusher {
        flusher = PerformanceFlusher(configuration: config, client: Client(configuration: config))
        return flusher
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func lastRequestJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(server.allRequests().last?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    func testBucketsByTransactionNameWithCountSumAndMax() {
        let flusher = makeFlusher(configuration())

        flusher.record(transactionName: "GET /users/:id", durationMs: 10)
        flusher.record(transactionName: "GET /users/:id", durationMs: 30)
        flusher.record(transactionName: "POST /orders", durationMs: 5)

        let users = flusher.tally(for: "GET /users/:id")
        XCTAssertEqual(users?.count, 2)
        XCTAssertEqual(users?.durationSumMs, 40)
        XCTAssertEqual(users?.maxDurationMs, 30)
        XCTAssertEqual(flusher.tally(for: "POST /orders")?.count, 1)
    }

    func testRecordDoesNothingWhenTrackPerformanceIsOff() {
        let config = configuration()
        config.trackPerformance = false
        let flusher = makeFlusher(config)

        flusher.record(transactionName: "GET /x", durationMs: 10)

        XCTAssertNil(flusher.tally(for: "GET /x"))
    }

    func testRecordDoesNothingWhenReportingIsNotEnabledForThisEnvironment() {
        let config = configuration()
        config.environment = "development"
        let flusher = makeFlusher(config)

        flusher.record(transactionName: "GET /x", durationMs: 10)

        XCTAssertNil(flusher.tally(for: "GET /x"))
    }

    func testFlushDeliversOneBatchToPerformanceSamplesAndEmptiesTheBuckets() throws {
        let config = configuration()
        config.releaseVersion = "a1b2c3d"
        let flusher = makeFlusher(config)
        flusher.record(transactionName: "GET /users/:id", durationMs: 10)
        flusher.record(transactionName: "GET /users/:id", durationMs: 30)

        flusher.flush()

        XCTAssertEqual(server.allRequests().count, 1)
        XCTAssertEqual(server.allRequests().first?.path, "/api/v1/performance_samples")
        let sample = try XCTUnwrap((lastRequestJSON()["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["transaction_name"] as? String, "GET /users/:id")
        XCTAssertEqual(sample["request_count"] as? Int, 2)
        XCTAssertEqual(sample["duration_sum_ms"] as? Double, 40)
        XCTAssertEqual(sample["max_duration_ms"] as? Double, 30)
        XCTAssertEqual(sample["environment"] as? String, "production")
        XCTAssertEqual(sample["release"] as? String, "a1b2c3d")
        XCTAssertTrue((sample["period_started_at"] as? String)?.hasSuffix("Z") ?? false)
        XCTAssertNil(flusher.tally(for: "GET /users/:id"))
    }

    func testFlushDoesNothingWhenThereIsNothingToSend() {
        let flusher = makeFlusher(configuration())

        flusher.flush()

        XCTAssertTrue(server.allRequests().isEmpty)
    }

    func testAFailedDeliveryKeepsEveryBucketSoTheNextFlushCarriesMore() throws {
        // /unauthorized answers 401 (and does not end in /events, so the URL is left as-is): a
        // failed delivery. Pointing the DSN at the normal path afterward is the retry that succeeds.
        let config = configuration(path: "/unauthorized")
        let flusher = makeFlusher(config)
        flusher.record(transactionName: "GET /x", durationMs: 10)

        flusher.flush()
        XCTAssertEqual(flusher.tally(for: "GET /x")?.count, 1)

        config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
        flusher.record(transactionName: "GET /x", durationMs: 20)
        flusher.flush()

        let sample = try XCTUnwrap((lastRequestJSON()["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["request_count"] as? Int, 2)
        XCTAssertNil(flusher.tally(for: "GET /x"))
    }

    func testARecordThatLandsDuringDeliveryIsNeverLost() {
        // Deterministic reproduction of the race flush's own comment describes: the hook runs
        // strictly between the snapshot and delivery succeeding, exactly where a record from
        // another thread could land.
        let flusher = makeFlusher(configuration())
        flusher.record(transactionName: "GET /x", durationMs: 10)
        flusher.beforeDeliveryHook = { [unowned flusher] in
            flusher.record(transactionName: "GET /x", durationMs: 25) // same transaction, mid-delivery
            flusher.record(transactionName: "GET /new", durationMs: 7) // a brand-new one, mid-delivery
        }

        flusher.flush()

        let x = flusher.tally(for: "GET /x")
        XCTAssertEqual(x?.count, 1)
        XCTAssertEqual(x?.durationSumMs, 25)
        XCTAssertEqual(x?.maxDurationMs, 25)
        XCTAssertEqual(flusher.tally(for: "GET /new")?.count, 1)
    }

    func testTheTimerFlushesOnItsOwnInterval() throws {
        let config = configuration()
        config.performanceFlushInterval = 0.05
        let flusher = makeFlusher(config)

        flusher.record(transactionName: "GET /x", durationMs: 10)

        XCTAssertTrue(waitUntil(timeout: 3.0) { self.server.allRequests().count >= 1 })
        let sample = try XCTUnwrap((lastRequestJSON()["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["transaction_name"] as? String, "GET /x")
    }

    func testDiscardCancelsTheTimerAndDeliversNothing() {
        let config = configuration()
        config.performanceFlushInterval = 0.05
        let flusher = makeFlusher(config)
        flusher.record(transactionName: "GET /x", durationMs: 10)

        flusher.discard()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(server.allRequests().isEmpty)
    }

    func testPerformanceSamplesURLSwapsTheTrailingEventsSegment() {
        let config = Configuration()
        config.dsn = "https://key@tracker.example.com/api/v1/events"

        XCTAssertEqual(config.performanceSamplesURL?.absoluteString, "https://tracker.example.com/api/v1/performance_samples")

        config.dsn = nil
        XCTAssertNil(config.performanceSamplesURL)
    }
}
