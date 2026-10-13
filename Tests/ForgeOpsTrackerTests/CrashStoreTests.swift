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

    private func backdate(_ url: URL, by interval: TimeInterval) throws {
        let date = Date().addingTimeInterval(-interval)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    func testPendingPayloadURLsKeepsOnlyTheNewestTwentyAndDeletesTheRest() throws {
        for i in 0 ..< CrashStore.maxPendingPayloads + 3 {
            XCTAssertTrue(store.write(payload: ["n": i]))
        }
        // Spread the creation times out by hand: oldest first, an hour apart.
        let written = try FileManager.default.contentsOfDirectory(atPath: config.crashReportsDirectory)
        var byNumber: [Int: URL] = [:]
        for name in written {
            let url = URL(fileURLWithPath: config.crashReportsDirectory).appendingPathComponent(name)
            let n = try XCTUnwrap(store.payload(at: url)?["n"] as? Int)
            byNumber[n] = url
            try backdate(url, by: TimeInterval((written.count - n) * 3600))
        }

        let urls = store.pendingPayloadURLs()

        XCTAssertEqual(urls.count, CrashStore.maxPendingPayloads)
        XCTAssertEqual(urls.compactMap { store.payload(at: $0)?["n"] as? Int }, Array(3 ..< CrashStore.maxPendingPayloads + 3))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.crashReportsDirectory).count, CrashStore.maxPendingPayloads)
        for n in 0 ..< 3 {
            XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(byNumber[n]).path))
        }
    }

    func testPendingPayloadURLsDeletesAnythingOlderThanSevenDays() throws {
        XCTAssertTrue(store.write(payload: ["n": "old"]))
        let old = store.pendingPayloadURLs()[0]
        try backdate(old, by: CrashStore.maxPendingPayloadAge + 3600)
        XCTAssertTrue(store.write(payload: ["n": "almost"]))
        let almost = try XCTUnwrap(store.pendingPayloadURLs().first { $0 != old })
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try backdate(almost, by: CrashStore.maxPendingPayloadAge - 3600)
        XCTAssertTrue(store.write(payload: ["n": "new"]))

        let urls = store.pendingPayloadURLs()

        XCTAssertEqual(urls.compactMap { store.payload(at: $0)?["n"] as? String }, ["almost", "new"])
    }

    func testPendingPayloadURLsIsEmptyWhenDirectoryDoesNotExist() {
        XCTAssertTrue(store.pendingPayloadURLs().isEmpty)
    }
}
