@testable import ForgeOpsTracker
import XCTest

final class CrashStoreTests: XCTestCase {
    private var config: Configuration!
    private var store: CrashStore!

    override func setUp() {
        super.setUp()
        config = Configuration()
        config.crashReportsDirectory = NSTemporaryDirectory() + "fot-crash-store-tests-\(UUID().uuidString)"
        store = CrashStore(configuration: config)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: config.crashReportsDirectory)
        super.tearDown()
    }

    func testWriteAndReadPayloadRoundTrips() {
        let payload: [String: Any] = ["exception_class": "Boom", "message": "bad"]

        XCTAssertTrue(store.write(payload: payload))

        let urls = store.pendingPayloadURLs()
        XCTAssertEqual(urls.count, 1)
        let read = store.payload(at: urls[0])
        XCTAssertEqual(read?["exception_class"] as? String, "Boom")
        XCTAssertEqual(read?["message"] as? String, "bad")
    }

    func testPendingPayloadURLsAreOldestFirst() {
        for i in 0 ..< 3 {
            XCTAssertTrue(store.write(payload: ["n": i]))
            Thread.sleep(forTimeInterval: 0.01) // ensure distinct creation timestamps
        }

        let urls = store.pendingPayloadURLs()
        let values = urls.compactMap { store.payload(at: $0)?["n"] as? Int }
        XCTAssertEqual(values, [0, 1, 2])
    }

    func testDeletePayloadRemovesIt() {
        XCTAssertTrue(store.write(payload: ["n": 1]))
        let url = store.pendingPayloadURLs()[0]

        store.deletePayload(at: url)

        XCTAssertTrue(store.pendingPayloadURLs().isEmpty)
    }

    func testPendingPayloadURLsIsEmptyWhenDirectoryDoesNotExist() {
        XCTAssertTrue(store.pendingPayloadURLs().isEmpty)
    }
}
