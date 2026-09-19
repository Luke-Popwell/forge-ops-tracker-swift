@testable import ForgeOpsTracker
import XCTest

final class MetricBufferTests: XCTestCase {
    private var server: TestHTTPServer!
    private var tempDirectory: String!
    private var buffers: [MetricBuffer] = []

    override func setUp() {
        super.setUp()
        ForgeOpsTracker._resetForTesting()
        tempDirectory = NSTemporaryDirectory() + UUID().uuidString
        server = TestHTTPServer()
        server.start()
        Thread.sleep(forTimeInterval: 0.05)
    }

    override func tearDown() {
        buffers.forEach { $0.discard() }
        buffers = []
        server.stop()
        try? FileManager.default.removeItem(atPath: tempDirectory)
        ForgeOpsTracker._resetForTesting()
        super.tearDown()
    }

    private func makeConfiguration() -> Configuration {
        let config = Configuration()
        config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
        config.enabledEnvironments = ["production"]
        config.environment = "production"
        config.releaseVersion = "a1b2c3d"
        config.serverName = "web-1"
        config.crashReportsDirectory = tempDirectory
        config.metricFlushInterval = 3600
        config.infrastructureMetricFlushInterval = 3600
        return config
    }

    private func makeBuffer(_ config: Configuration, interval: @escaping () -> TimeInterval = { 3600 }, deliver: @escaping ([[String: Any]]) -> Bool) -> MetricBuffer {
        let buffer = MetricBuffer(configuration: config, deliver: deliver, interval: interval)
        buffers.append(buffer)
        return buffer
    }

    private func names(_ entries: [[String: Any]]) -> [String] {
        entries.compactMap { $0["metric_name"] as? String }
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    func testDeliversEveryEntryAsOneBatchStampedWithRecordedAt() throws {
        var delivered: [[[String: Any]]] = []
        let buffer = makeBuffer(makeConfiguration()) { delivered.append($0); return true }

        XCTAssertTrue(buffer.record(["metric_name": "signup", "value": 1.0]))
        XCTAssertTrue(buffer.record(["metric_name": "refund", "value": -12.5]))
        buffer.flush()

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(names(delivered[0]), ["signup", "refund"])
        XCTAssertEqual(delivered[0][1]["value"] as? Double, -12.5)
        let stamp = try XCTUnwrap(delivered[0][0]["recorded_at"] as? String)
        XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"#, options: .regularExpression))
        XCTAssertEqual(buffer.count, 0)
    }

    func testDropsNaNInfiniteAndNonNumericValuesSinceJSONSerializationWouldCrashTheApp() {
        let buffer = makeBuffer(makeConfiguration()) { _ in true }
        XCTAssertFalse(buffer.record(["metric_name": "nan", "value": Double.nan]))
        XCTAssertFalse(buffer.record(["metric_name": "inf", "value": Double.infinity]))
        XCTAssertFalse(buffer.record(["metric_name": "str", "value": "12"]))
        XCTAssertFalse(buffer.record(["metric_name": "missing"]))
        XCTAssertTrue(buffer.record(["metric_name": "ok", "value": 3]))
    }

    func testAFailedDeliveryKeepsEveryEntryForTheNextFlush() {
        var calls = 0
        var delivered: [[String]] = []
        let buffer = makeBuffer(makeConfiguration()) { entries in
            delivered.append(self.names(entries))
            calls += 1
            return calls > 1
        }

        buffer.record(["metric_name": "a", "value": 1])
        buffer.flush()
        buffer.record(["metric_name": "b", "value": 2])
        buffer.flush()
        buffer.flush() // nothing left: no third delivery

        XCTAssertEqual(delivered, [["a"], ["a", "b"]])
    }

    func testAnEntryRecordedWhileDeliveryIsInFlightIsNeverLost() {
        var delivered: [[String]] = []
        let buffer = makeBuffer(makeConfiguration()) { delivered.append(self.names($0)); return true }
        buffer.record(["metric_name": "first", "value": 1])
        buffer.beforeDeliveryHook = { [unowned buffer] in buffer.record(["metric_name": "during", "value": 2]) }

        buffer.flush()
        buffer.beforeDeliveryHook = nil
        buffer.flush()

        XCTAssertEqual(delivered, [["first"], ["during"]])
    }

    func testIsCappedAndDropsFurtherEntriesUntilAFlushSucceeds() {
        let buffer = makeBuffer(makeConfiguration()) { _ in false }
        var accepted = 0
        for _ in 0 ..< MetricBuffer.maxEntries + 50 where buffer.record(["metric_name": "m", "value": 1]) {
            accepted += 1
        }
        XCTAssertEqual(accepted, MetricBuffer.maxEntries)
    }

    func testTheTimerFlushesOnItsOwnInterval() {
        let lock = NSLock()
        var count = 0
        let buffer = makeBuffer(makeConfiguration(), interval: { 0.05 }) { _ in
            lock.lock()
            count += 1
            lock.unlock()
            return true
        }

        buffer.record(["metric_name": "tick", "value": 1])

        XCTAssertTrue(waitUntil { lock.lock(); defer { lock.unlock() }; return count >= 1 })
    }

    func testCaptureMetricAndCaptureInfrastructureMetricDeliverToTheirOwnEndpointsThroughTheFullStack() throws {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.releaseVersion = "a1b2c3d"
            config.serverName = "web-1"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.captureMetric("signup")
        ForgeOpsTracker.captureMetric("payment", value: 49)
        ForgeOpsTracker.captureInfrastructureMetric("cpu", value: 0.42, hostname: "db-1")
        ForgeOpsTracker.captureInfrastructureMetric("memory", value: 0.7)
        ForgeOpsTracker.flushMetrics()

        let requests = server.allRequests()
        XCTAssertEqual(requests.count, 2)
        let custom = try XCTUnwrap(requests.first { $0.path == "/api/v1/custom_metrics" })
        let infrastructure = try XCTUnwrap(requests.first { $0.path == "/api/v1/infrastructure_metrics" })
        XCTAssertEqual(custom.headers["Authorization"], "Bearer key")
        let customBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(custom.body.utf8)) as? [String: Any])
        let metrics = try XCTUnwrap(customBody["metrics"] as? [[String: Any]])
        XCTAssertEqual(names(metrics), ["signup", "payment"])
        XCTAssertEqual(metrics[0]["value"] as? Double, 1)
        XCTAssertEqual(metrics[1]["value"] as? Double, 49)
        XCTAssertEqual(metrics[0]["environment"] as? String, "production")
        XCTAssertEqual(metrics[0]["release"] as? String, "a1b2c3d")
        let infraBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(infrastructure.body.utf8)) as? [String: Any])
        let readings = try XCTUnwrap(infraBody["metrics"] as? [[String: Any]])
        XCTAssertEqual(readings[0]["hostname"] as? String, "db-1")
        XCTAssertEqual(readings[1]["hostname"] as? String, "web-1")
    }

    func testCapturesAreANoOpWhenReportingIsNotEnabledForThisEnvironment() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.environment = "development"
            config.crashReportsDirectory = tempDirectory
        }
        ForgeOpsTracker.captureMetric("signup")
        ForgeOpsTracker.captureInfrastructureMetric("cpu", value: 1)
        ForgeOpsTracker.flushMetrics()

        XCTAssertEqual(server.allRequests().count, 0)
    }

    func testAnInfrastructureReadingWithNoHostnameIsDroppedRatherThanSent() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }
        ForgeOpsTracker.captureInfrastructureMetric("cpu", value: 1)
        ForgeOpsTracker.flushMetrics()

        XCTAssertEqual(server.allRequests().count, 0)
    }

    func testTheMetricURLsSwapTheTrailingEventsSegment() {
        let config = Configuration()
        config.dsn = "https://key@tracker.example.com/api/v1/events"
        XCTAssertEqual(config.customMetricsURL?.absoluteString, "https://tracker.example.com/api/v1/custom_metrics")
        XCTAssertEqual(config.infrastructureMetricsURL?.absoluteString, "https://tracker.example.com/api/v1/infrastructure_metrics")
    }
}
