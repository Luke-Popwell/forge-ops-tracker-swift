@testable import ForgeOpsTracker
import XCTest

final class BreadcrumbBufferTests: XCTestCase {
    private var tempDirectory: String!

    override func setUp() {
        super.setUp()
        tempDirectory = NSTemporaryDirectory() + UUID().uuidString
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDirectory)
        try? FileManager.default.removeItem(atPath: tempDirectory + ".breadcrumbs.json")
        super.tearDown()
    }

    private func configuration() -> Configuration {
        let config = Configuration()
        config.crashReportsDirectory = tempDirectory
        return config
    }

    func testRecordsEntriesInOrderWithTheWireShape() {
        let buffer = BreadcrumbBuffer(configuration: configuration())

        buffer.add(message: "first", category: "custom", level: "info", data: [:])
        buffer.add(message: "second", category: "payment", level: "warning", data: ["order_id": 42])

        let all = buffer.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0]["message"] as? String, "first")
        XCTAssertEqual((all[0]["data"] as? [String: Any])?.count, 0)
        XCTAssertEqual(all[1]["category"] as? String, "payment")
        XCTAssertEqual(all[1]["level"] as? String, "warning")
        XCTAssertEqual((all[1]["data"] as? [String: Any])?["order_id"] as? Int, 42)
        XCTAssertTrue((all[1]["timestamp"] as? String)?.hasSuffix("Z") ?? false)
    }

    func testDropsTheOldestEntriesPastMaxBreadcrumbs() {
        let config = configuration()
        config.maxBreadcrumbs = 2
        let buffer = BreadcrumbBuffer(configuration: config)

        for message in ["first", "second", "third"] {
            buffer.add(message: message, category: "custom", level: "info", data: [:])
        }

        XCTAssertEqual(buffer.all().compactMap { $0["message"] as? String }, ["second", "third"])
    }

    func testRecordsNothingWhenTrackBreadcrumbsIsOff() {
        let config = configuration()
        config.trackBreadcrumbs = false
        let buffer = BreadcrumbBuffer(configuration: config)

        buffer.add(message: "nope", category: "custom", level: "info", data: [:])

        XCTAssertTrue(buffer.all().isEmpty)
    }

    func testClearEmptiesTheTrail() {
        let buffer = BreadcrumbBuffer(configuration: configuration())
        buffer.add(message: "first", category: "custom", level: "info", data: [:])

        buffer.clear()

        XCTAssertTrue(buffer.all().isEmpty)
    }

    func testIsSafeToAddFromManyThreadsAtOnce() {
        let config = configuration()
        config.maxBreadcrumbs = 50
        let buffer = BreadcrumbBuffer(configuration: config)

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            buffer.add(message: "crumb \(i)", category: "custom", level: "info", data: [:])
            _ = buffer.all()
        }

        XCTAssertEqual(buffer.all().count, 50, "exactly the cap, no lost or duplicated slots")
    }

    func testNothingIsWrittenToDiskUntilPersistingStarts() {
        let buffer = BreadcrumbBuffer(configuration: configuration())

        buffer.add(message: "first", category: "custom", level: "info", data: [:])
        buffer._waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDirectory + ".breadcrumbs.json"))
    }

    func testAPersistedTrailSurvivesIntoTheNextRunAsThePreviousRunsTrail() {
        let config = configuration()
        let crashedRun = BreadcrumbBuffer(configuration: config)
        crashedRun.startPersisting()
        crashedRun.add(message: "charging card", category: "payment", level: "info", data: ["order_id": 42])
        crashedRun._waitForPendingWrites()

        // A brand-new instance over the same configuration stands in for the next launch.
        let nextRun = BreadcrumbBuffer(configuration: config)
        nextRun.startPersisting()

        let previous = nextRun.previousRunBreadcrumbs(forCrashOccurringAt: Date().addingTimeInterval(1))
        XCTAssertEqual(previous?.count, 1)
        XCTAssertEqual(previous?.first?["message"] as? String, "charging card")
        XCTAssertTrue(nextRun.all().isEmpty, "the new run's own trail starts empty")
    }

    func testThePreviousRunsTrailIsNotAttachedToACrashThatHappenedBeforeItsLastWrite() {
        let config = configuration()
        let earlierRun = BreadcrumbBuffer(configuration: config)
        earlierRun.startPersisting()
        earlierRun.add(message: "written after that crash", category: "custom", level: "info", data: [:])
        earlierRun._waitForPendingWrites()

        let nextRun = BreadcrumbBuffer(configuration: config)
        nextRun.startPersisting()

        // A crash a minute before that trail was last written: a later run replaced whatever
        // trail that crash left behind, so this one would be misleading.
        XCTAssertNil(nextRun.previousRunBreadcrumbs(forCrashOccurringAt: Date().addingTimeInterval(-60)))
    }

    func testThePersistedTrailIsPiiScrubbedOnDisk() throws {
        let buffer = BreadcrumbBuffer(configuration: configuration())
        buffer.startPersisting()
        buffer.add(message: "emailed alice@example.com", category: "custom", level: "info", data: ["password": "hunter2"])
        buffer._waitForPendingWrites()

        let onDisk = try String(contentsOfFile: tempDirectory + ".breadcrumbs.json", encoding: .utf8)
        XCTAssertFalse(onDisk.contains("alice@example.com"))
        XCTAssertFalse(onDisk.contains("hunter2"))
        XCTAssertTrue((buffer.all().first?["message"] as? String)?.contains("alice@example.com") ?? false, "the in-memory copy is untouched")
    }

    func testThePersistedFileIsNeverMistakenForAPendingCrashReport() {
        let config = configuration()
        let buffer = BreadcrumbBuffer(configuration: config)
        buffer.startPersisting()
        buffer.add(message: "first", category: "custom", level: "info", data: [:])
        buffer._waitForPendingWrites()

        XCTAssertTrue(CrashStore(configuration: config).pendingPayloadURLs().isEmpty)
    }
}
