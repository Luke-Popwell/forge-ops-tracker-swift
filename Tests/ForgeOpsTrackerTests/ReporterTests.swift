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
}
