import CFOTTestSupport
@testable import ForgeOpsTracker
import XCTest

final class ForgeOpsTrackerTests: XCTestCase {
    private var server: TestHTTPServer!
    private var tempDirectory: String!

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
        try? FileManager.default.removeItem(atPath: tempDirectory + ".breadcrumbs.json")
        ForgeOpsTracker._resetForTesting()
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    func testConfigureConfiguresAndReturnsTheConfiguration() {
        let config = ForgeOpsTracker.configure { c in
            c.dsn = "https://key@tracker.example.com/api/v1/events"
            c.releaseVersion = "abc123"
        }

        XCTAssertEqual(config.dsn, "https://key@tracker.example.com/api/v1/events")
        XCTAssertEqual(config.releaseVersion, "abc123")
    }

    func testCaptureExceptionDeliversThroughTheFullStack() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        let exception = FOTRaiseAndCatchTestException("TestException", "boom")
        ForgeOpsTracker.captureException(exception)

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertEqual(server.allRequests().last?.headers["Authorization"], "Bearer key")
    }

    func testCaptureErrorDeliversThroughTheFullStack() {
        struct SampleError: Error {}

        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.capture(error: SampleError())

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertTrue(server.allRequests().last?.body.contains("SampleError") ?? false)
    }

    func testSetUserAttachesTheUserToALaterCaptureExceptionCall() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.setUser(["id": 42, "email": "alice@example.com"])
        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("TestException", "boom"))

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertTrue(server.allRequests().last?.body.contains("alice@example.com") ?? false)
    }

    func testAnExplicitUserArgumentOverridesWhateverSetUserLastSet() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.setUser(["id": 42])
        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("TestException", "boom"), user: ["id": 99])

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertTrue(server.allRequests().last?.body.contains("\"id\":99") ?? false)
    }

    func testResetForTestingClearsTheCurrentUser() {
        ForgeOpsTracker.setUser(["id": 42])
        ForgeOpsTracker._resetForTesting()

        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }
        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("TestException", "boom"))

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertFalse(server.allRequests().last?.body.contains("\"user\"") ?? true)
    }

    func testInstallHandlersIsIdempotent() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.crashReportsDirectory = tempDirectory
        }

        // Must not crash or double-install on a second call: same "call once, redundant calls
        // are safe no-ops" contract as installHandlers documents.
        ForgeOpsTracker.installHandlers()
        ForgeOpsTracker.installHandlers()
    }

    func testAddBreadcrumbAttachesTheTrailToALaterCaptureExceptionCall() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.addBreadcrumb("charging card", category: "payment", data: ["order_id": 42])
        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("TestException", "boom"))

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        let body = server.allRequests().last?.body ?? ""
        XCTAssertTrue(body.contains("charging card"))
        XCTAssertTrue(body.contains("\"category\":\"payment\""))
    }

    func testAddBreadcrumbAttachesTheTrailToACapturedSwiftError() {
        struct SampleError: Error {}
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.addBreadcrumb("about to fail")
        ForgeOpsTracker.capture(error: SampleError())

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertTrue(server.allRequests().last?.body.contains("about to fail") ?? false)
    }

    func testAddBreadcrumbDefaultsToTheCustomCategoryAndInfoLevel() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.addBreadcrumb("something happened")

        let crumb = ForgeOpsTracker.currentBreadcrumbs.first
        XCTAssertEqual(crumb?["category"] as? String, "custom")
        XCTAssertEqual(crumb?["level"] as? String, "info")
    }

    func testClearBreadcrumbsEmptiesTheTrail() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.addBreadcrumb("first")
        ForgeOpsTracker.clearBreadcrumbs()
        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("TestException", "boom"))

        XCTAssertTrue(waitUntil { self.server.allRequests().count >= 1 })
        XCTAssertFalse(server.allRequests().last?.body.contains("\"breadcrumbs\"") ?? true)
    }

    func testResetForTestingClearsTheBreadcrumbTrail() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        ForgeOpsTracker.addBreadcrumb("leftover")
        ForgeOpsTracker._resetForTesting()

        XCTAssertTrue(ForgeOpsTracker.currentBreadcrumbs.isEmpty)
    }

    func testARawSignalCrashReportCarriesThePreviousRunsPersistedTrail() throws {
        let config = ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
        }

        // The crashed run: persisting, breadcrumbs added, then it dies (nothing else to simulate:
        // the trail is already on disk). Raw signal report as SignalHandler leaves it.
        let crashedRun = BreadcrumbBuffer(configuration: config)
        crashedRun.startPersisting()
        crashedRun.add(message: "charging card", category: "payment", level: "info", data: [:])
        crashedRun._waitForPendingWrites()
        try FileManager.default.createDirectory(atPath: tempDirectory, withIntermediateDirectories: true)
        try "Segmentation fault: 11\n0   libsystem_c.dylib  0x0000000000001 abort + 1\n"
            .write(toFile: tempDirectory + "/signal-11-1.txt", atomically: true, encoding: .utf8)

        // The next launch.
        ForgeOpsTracker._startBreadcrumbPersistence()
        ForgeOpsTracker.captureException(FOTRaiseAndCatchTestException("Unrelated", "triggers an upload"))

        XCTAssertTrue(waitUntil(timeout: 3.0) { self.server.allRequests().count >= 2 })
        let signalBody = server.allRequests().first { $0.body.contains("Uncaught fatal signal") }?.body
        XCTAssertNotNil(signalBody)
        XCTAssertTrue(signalBody?.contains("charging card") ?? false)
    }

    func testRecordPerformanceAndFlushPerformanceDeliverThroughTheFullStack() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
            config.performanceFlushInterval = 3600 // flushed by hand below
        }

        ForgeOpsTracker.recordPerformance("GET /users/:id", durationMs: 10)
        ForgeOpsTracker.recordPerformance("GET /users/:id", durationMs: 30)
        ForgeOpsTracker.flushPerformance()

        XCTAssertEqual(server.allRequests().count, 1)
        let body = server.allRequests().last?.body ?? ""
        XCTAssertTrue(body.contains("GET \\/users\\/:id") || body.contains("GET /users/:id"))
        XCTAssertTrue(body.contains("\"request_count\":2"))
    }

    func testMeasureTransactionReturnsTheBodysValueAndRecordsHowLongItTook() throws {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
            config.performanceFlushInterval = 3600 // flushed by hand below
        }

        let value = ForgeOpsTracker.measureTransaction("timed") { () -> Int in
            Thread.sleep(forTimeInterval: 0.03)
            return 42
        }
        ForgeOpsTracker.flushPerformance()

        XCTAssertEqual(value, 42)
        let body = try XCTUnwrap(server.allRequests().last?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let sample = try XCTUnwrap((json["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(sample["transaction_name"] as? String, "timed")
        XCTAssertGreaterThanOrEqual(sample["duration_sum_ms"] as? Double ?? 0, 25)
    }

    func testMeasureTransactionRecordsEvenWhenTheBodyThrowsAndRethrowsItUnchanged() {
        struct SampleError: Error, Equatable {}
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
            config.performanceFlushInterval = 3600 // flushed by hand below
        }

        XCTAssertThrowsError(try ForgeOpsTracker.measureTransaction("timed throws") { throw SampleError() }) { error in
            XCTAssertEqual(error as? SampleError, SampleError())
        }
        ForgeOpsTracker.flushPerformance()

        XCTAssertTrue(server.allRequests().last?.body.contains("timed throws") ?? false)
    }

    func testTrackPerformanceOffRecordsAndDeliversNothing() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = "production"
            config.crashReportsDirectory = tempDirectory
            config.trackPerformance = false
        }

        ForgeOpsTracker.recordPerformance("never recorded", durationMs: 10)
        ForgeOpsTracker.flushPerformance()

        XCTAssertTrue(server.allRequests().isEmpty)
    }
}
