import CFOTTestSupport
@testable import ForgeOpsTracker
import XCTest

final class EventBuilderTests: XCTestCase {
    private func testConfiguration() -> Configuration {
        let config = Configuration()
        config.environment = "production"
        config.releaseVersion = "a1b2c3d"
        config.serverName = "test-host"
        return config
    }

    // Raises a real NSException, from a real call stack, rather than constructing one with
    // NSException(name:reason:userInfo:) directly -- confirmed directly that -callStackSymbols is
    // empty unless the exception is actually raised. Goes through CFOTTestSupport's Objective-C
    // helper rather than raising it here: Swift's do/catch cannot catch an NSException at all, so
    // raising one directly in Swift would crash the test process instead of being caught.
    private func raiseAndCatch() -> NSException {
        FOTRaiseAndCatchTestException("TestException", "boom")
    }

    func testBuildEventForExceptionBasicFields() {
        let config = testConfiguration()
        let exception = raiseAndCatch()

        let event = EventBuilder.buildEvent(exception: exception, configuration: config, context: ["order_id": 42])

        XCTAssertEqual(event["exception_class"] as? String, "TestException")
        XCTAssertEqual(event["message"] as? String, "boom")
        XCTAssertEqual(event["environment"] as? String, "production")
        XCTAssertEqual(event["release"] as? String, "a1b2c3d")
        XCTAssertEqual(event["server_name"] as? String, "test-host")
        let context = event["context"] as? [String: Any]
        XCTAssertEqual(context?["order_id"] as? Int, 42)
    }

    func testBuildEventForExceptionParsesBacktrace() {
        let config = testConfiguration()
        let exception = raiseAndCatch()

        let event = EventBuilder.buildEvent(exception: exception, configuration: config, context: nil)
        guard let backtrace = event["backtrace"] as? [[String: Any]] else {
            return XCTFail("expected a backtrace array")
        }

        XCTAssertFalse(backtrace.isEmpty, "expected at least one parsed frame from a real raised exception")
        for frame in backtrace {
            XCTAssertNotNil(frame["file"] as? String)
            XCTAssertNotNil(frame["method"] as? String)
            XCTAssertNotNil(frame["in_app"] as? Bool)
        }
    }

    func testMarksAFrameFromThisTestBinaryAsInApp() {
        let config = testConfiguration()
        let exception = raiseAndCatch()

        let event = EventBuilder.buildEvent(exception: exception, configuration: config, context: nil)
        let backtrace = event["backtrace"] as? [[String: Any]] ?? []

        let anyInApp = backtrace.contains { ($0["in_app"] as? Bool) == true }
        XCTAssertTrue(anyInApp, "the frame that raised the exception should be in this test bundle's own binary")
    }

    private struct SampleError: Error, LocalizedError {
        var errorDescription: String? { "sample failure" }
    }

    func testBuildEventForSwiftError() {
        let config = testConfiguration()
        let event = EventBuilder.buildEvent(error: SampleError(), configuration: config, context: nil)

        XCTAssertTrue((event["exception_class"] as? String)?.contains("SampleError") ?? false)
        XCTAssertEqual(event["message"] as? String, "sample failure")
        XCTAssertNotNil(event["backtrace"] as? [[String: Any]])
    }

    func testBuildEventScrubsMessageAndContextWhenEnabled() {
        let config = testConfiguration()
        config.scrubPII = true
        let exception = NSException(name: NSExceptionName("TestException"), reason: "failed to charge user@example.com", userInfo: nil)

        let event = EventBuilder.buildEvent(exception: exception, configuration: config, context: ["api_key": "shh-secret"])

        XCTAssertEqual(event["message"] as? String, "failed to charge [EMAIL FILTERED]")
        let context = event["context"] as? [String: Any]
        XCTAssertEqual(context?["api_key"] as? String, PiiScrubber.redacted)
    }

    func testBuildEventDoesNotScrubWhenDisabled() {
        let config = testConfiguration()
        config.scrubPII = false
        let exception = NSException(name: NSExceptionName("TestException"), reason: "contact user@example.com", userInfo: nil)

        let event = EventBuilder.buildEvent(exception: exception, configuration: config, context: nil)

        XCTAssertEqual(event["message"] as? String, "contact user@example.com")
    }
}
