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

    func testInstallHandlersIsIdempotent() {
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(server.port)/api/v1/events"
            config.crashReportsDirectory = tempDirectory
        }

        // Must not crash or double-install on a second call -- same "call once, redundant calls
        // are safe no-ops" contract as installHandlers documents.
        ForgeOpsTracker.installHandlers()
        ForgeOpsTracker.installHandlers()
    }
}
