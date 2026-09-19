@testable import ForgeOpsTracker
import XCTest

final class SignalHandlerTests: XCTestCase {
    // Installing the real handlers (registration succeeding) is what's tested here: actually
    // raising a fatal signal to test the handler's own body would crash this test process itself,
    // the same reason every real crash reporter's signal path is validated by manual/integration
    // crash testing, not a unit test. See CFOTSignal's own header comment.
    func testInstallingRegistersHandlersWithoutCrashing() {
        let directory = NSTemporaryDirectory() + "fot-signal-handler-tests-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        SignalHandler.install(directory: directory)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue)
    }

    func testParseRawSignalReportParsesSignalNameAndBacktraceLines() throws {
        let directory = NSTemporaryDirectory() + "fot-signal-handler-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let contents = "Segmentation fault\n0   MyApp 0x0000000100000000 main + 0\n1   MyApp 0x0000000100000010 start + 0\n"
        let path = directory + "/signal-11-123.txt"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)

        let parsed = SignalHandler.parseRawSignalReport(at: URL(fileURLWithPath: path))

        XCTAssertEqual(parsed?["exception_class"] as? String, "Signal: Segmentation fault")
        XCTAssertEqual(parsed?["message"] as? String, "Uncaught fatal signal: Segmentation fault")
        let backtrace = parsed?["backtrace"] as? [[String: Any]]
        XCTAssertEqual(backtrace?.count, 2)
        XCTAssertEqual(backtrace?[0]["method"] as? String, "0   MyApp 0x0000000100000000 main + 0")
        XCTAssertEqual(backtrace?[0]["in_app"] as? Bool, false)
    }

    func testParseRawSignalReportReturnsNilForAMissingFile() {
        let parsed = SignalHandler.parseRawSignalReport(at: URL(fileURLWithPath: "/nonexistent/path.txt"))
        XCTAssertNil(parsed)
    }
}
