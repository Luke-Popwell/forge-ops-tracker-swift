import CFOTTestSupport
@testable import ForgeOpsTracker
import XCTest

final class ReporterTests: XCTestCase {
    private var config: Configuration!

    override func setUp() {
        super.setUp()
        StubURLProtocol.recorded = []
        StubURLProtocol.statusCode = 200
        config = Configuration()
        config.dsn = "https://key@forgeops.example/events"
        config.environment = "production"
        config.crashReportsDirectory = NSTemporaryDirectory() + "fot-reporter-tests-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: config.crashReportsDirectory)
        super.tearDown()
    }

    private func reporter() -> Reporter {
        Reporter(configuration: config, client: Client(configuration: config, protocolClasses: [StubURLProtocol.self]))
    }

    func testReportExceptionDoesNothingWhenDisabled() {
        config.environment = "development" // not in enabledEnvironments
        let exception = FOTRaiseAndCatchTestException("Boom", "bad")

        reporter().report(exception: exception, context: nil)

        XCTAssertTrue(CrashStore(configuration: config).pendingPayloadURLs().isEmpty)
    }

    func testReportExceptionWritesAPendingCrashReport() {
        let exception = FOTRaiseAndCatchTestException("Boom", "bad")

        reporter().report(exception: exception, context: nil)

        XCTAssertEqual(CrashStore(configuration: config).pendingPayloadURLs().count, 1)
    }

    func testReportErrorWritesAPendingCrashReport() {
        struct SampleError: Error {}

        reporter().report(error: SampleError(), context: nil)

        XCTAssertEqual(CrashStore(configuration: config).pendingPayloadURLs().count, 1)
    }

    func testReportExceptionIncludesTheGivenUserNeverScrubbedEvenThoughItsAnEmail() {
        let r = reporter()
        r.report(exception: FOTRaiseAndCatchTestException("Boom", "bad"), context: nil, user: ["id": 42, "email": "alice@example.com"])

        r.uploadPendingReports()

        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        XCTAssertTrue(StubURLProtocol.recorded[0].bodyString?.contains("alice@example.com") ?? false)
    }

    func testUploadPendingReportsDeliversAndDeletesOnSuccess() {
        let r = reporter()
        r.report(exception: FOTRaiseAndCatchTestException("Boom", "bad"), context: nil)
        XCTAssertEqual(CrashStore(configuration: config).pendingPayloadURLs().count, 1)

        r.uploadPendingReports()

        XCTAssertTrue(CrashStore(configuration: config).pendingPayloadURLs().isEmpty)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testUploadPendingReportsLeavesAFileInPlaceOnDeliveryFailure() {
        StubURLProtocol.statusCode = 500
        let r = reporter()
        r.report(exception: FOTRaiseAndCatchTestException("Boom", "bad"), context: nil)

        r.uploadPendingReports()

        XCTAssertEqual(CrashStore(configuration: config).pendingPayloadURLs().count, 1)
    }

    func testUploadPendingReportsLeavesAFileInPlaceWhenTheServerIsUnreachable() {
        config.dsn = "http://key@127.0.0.1:1/events" // nothing listens there
        config.timeout = 0.5
        let r = Reporter(configuration: config, client: Client(configuration: config))
        r.report(exception: FOTRaiseAndCatchTestException("Boom", "bad"), context: nil)

        r.uploadPendingReports()

        XCTAssertEqual(CrashStore(configuration: config).pendingPayloadURLs().count, 1)
    }

    func testUploadPendingReportsDeletesAReportTheServerRejectsAndNeverSendsItAgain() {
        StubURLProtocol.statusCode = 422
        let r = reporter()
        r.report(exception: FOTRaiseAndCatchTestException("Boom", "bad"), context: nil)

        r.uploadPendingReports()
        XCTAssertTrue(CrashStore(configuration: config).pendingPayloadURLs().isEmpty)

        r.uploadPendingReports()
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
    }

    func testUploadPendingReportsKeepsAReportTheServerAsksToRetry() {
        let r = reporter()
        r.report(exception: FOTRaiseAndCatchTestException("Boom", "bad"), context: nil)

        for status in [408, 429] {
            StubURLProtocol.statusCode = status
            r.uploadPendingReports()
            XCTAssertEqual(CrashStore(configuration: config).pendingPayloadURLs().count, 1)
        }
    }

    func testARejectedReportDoesNotHoldUpTheOnesBehindIt() {
        let r = reporter()
        r.report(exception: FOTRaiseAndCatchTestException("First", "bad"), context: nil)
        Thread.sleep(forTimeInterval: 0.01)
        r.report(exception: FOTRaiseAndCatchTestException("Second", "bad"), context: nil)
        StubURLProtocol.statusCode = 400

        r.uploadPendingReports()

        XCTAssertEqual(StubURLProtocol.recorded.count, 2)
        XCTAssertTrue(CrashStore(configuration: config).pendingPayloadURLs().isEmpty)
    }
}
