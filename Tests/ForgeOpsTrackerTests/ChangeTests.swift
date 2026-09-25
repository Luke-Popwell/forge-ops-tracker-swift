@testable import ForgeOpsTracker
import XCTest

final class ChangeTests: XCTestCase {
    private var server: TestHTTPServer!
    private var tempDirectory: String!

    override func setUp() {
        super.setUp()
        ForgeOpsTracker._resetForTesting()
        StubURLProtocol.recorded = []
        StubURLProtocol.statusCode = 200
        tempDirectory = NSTemporaryDirectory() + UUID().uuidString
        server = TestHTTPServer()
        server.start()
        Thread.sleep(forTimeInterval: 0.05)
    }

    override func tearDown() {
        ForgeOpsTracker._resetForTesting()
        server.stop()
        try? FileManager.default.removeItem(atPath: tempDirectory)
        StubURLProtocol.recorded = []
        StubURLProtocol.statusCode = 200
        super.tearDown()
    }

    private func configure(environment: String = "production", port: UInt16? = nil) {
        let port = port ?? server.port
        ForgeOpsTracker.configure { config in
            config.dsn = "http://key@127.0.0.1:\(port)/api/v1/events"
            config.enabledEnvironments = ["production"]
            config.environment = environment
            config.crashReportsDirectory = tempDirectory
        }
    }

    private func body(_ request: (method: String, path: String, headers: [String: String], body: String)) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
    }

    func testRecordChangePostsThePayloadToTheChangesEndpoint() throws {
        configure()

        ForgeOpsTracker.recordChange(
            "feature_flag",
            title: "new_checkout turned on",
            details: ["key": "new_checkout", "from": false, "to": true],
            service: "ios-app",
            actor: "flag-service",
            url: "https://flags.example.com/new_checkout",
            id: "flag-123",
            occurredAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        ForgeOpsTracker._waitForChanges()

        let requests = server.allRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/changes")
        XCTAssertEqual(request.headers["Authorization"], "Bearer key")

        let sent = try body(request)
        XCTAssertEqual(sent["kind"] as? String, "feature_flag")
        XCTAssertEqual(sent["title"] as? String, "new_checkout turned on")
        XCTAssertEqual(sent["environment"] as? String, "production")
        XCTAssertEqual(sent["service"] as? String, "ios-app")
        XCTAssertEqual(sent["actor"] as? String, "flag-service")
        XCTAssertEqual(sent["url"] as? String, "https://flags.example.com/new_checkout")
        XCTAssertEqual(sent["id"] as? String, "flag-123")
        XCTAssertEqual(sent["occurred_at"] as? String, "2026-09-21T14:13:20.000Z")
        let details = try XCTUnwrap(sent["details"] as? [String: Any])
        XCTAssertEqual(details["key"] as? String, "new_checkout")
        XCTAssertEqual(details["to"] as? Bool, true)
    }

    func testOptionalFieldsAreLeftOutAndOccurredAtDefaultsToNow() throws {
        configure()

        ForgeOpsTracker.recordChange("config", title: "checkout timeout raised")
        ForgeOpsTracker._waitForChanges()

        let sent = try body(try XCTUnwrap(server.allRequests().first))
        XCTAssertEqual(Set(sent.keys), ["kind", "title", "environment", "occurred_at"])
        XCTAssertNotNil(ISO8601DateFormatter.withFractionalSeconds.date(from: sent["occurred_at"] as? String ?? ""))
    }

    func testAnUnknownKindIsSentAsOther() {
        for kind in ["feature_flag", "config", "migration", "dependency", "infrastructure", "other"] {
            XCTAssertEqual(Change.normalizedKind(kind), kind)
        }
        XCTAssertEqual(Change.normalizedKind("flag"), "other")
        XCTAssertEqual(Change.normalizedKind(""), "other")
    }

    func testTitleIsTruncatedAndABlankTitleIsDropped() {
        let config = Configuration()
        let long = Change.payload(kind: "other", title: String(repeating: "a", count: 250), details: nil, environment: nil,
                                  service: nil, actor: nil, url: nil, id: nil, occurredAt: nil, configuration: config)
        XCTAssertEqual((long?["title"] as? String)?.count, 200)

        configure()
        ForgeOpsTracker.recordChange("other", title: "   ")
        ForgeOpsTracker._waitForChanges()
        XCTAssertEqual(server.allRequests().count, 0)
    }

    func testDetailsJSONSerializationCannotEncodeAndANonHTTPURLAreLeftOutInsteadOfCrashing() {
        let payload = Change.payload(kind: "config", title: "x", details: ["ratio": Double.nan], environment: "qa",
                                     service: nil, actor: nil, url: "javascript:alert(1)", id: nil, occurredAt: nil,
                                     configuration: Configuration())
        XCTAssertNil(payload?["details"])
        XCTAssertNil(payload?["url"])
        XCTAssertEqual(payload?["environment"] as? String, "qa")
    }

    func testIsANoOpWhenReportingIsNotEnabled() {
        configure(environment: "development")

        ForgeOpsTracker.recordChange("feature_flag", title: "ignored")
        ForgeOpsTracker._waitForChanges()

        XCTAssertEqual(server.allRequests().count, 0)
    }

    func testNeverFailsTheCallerWhenTheServerIsUnreachableOrRejectsTheChange() {
        // Nothing listens on a port this server just released.
        let closed = server.port
        server.stop()
        configure(port: closed)
        ForgeOpsTracker.recordChange("feature_flag", title: "unreachable")
        ForgeOpsTracker._waitForChanges()

        let config = Configuration()
        config.dsn = "https://key@tracker.example.com/api/v1/events"
        StubURLProtocol.statusCode = 403
        let client = Client(configuration: config, protocolClasses: [StubURLProtocol.self])
        XCTAssertFalse(client.deliverChange(["kind": "other", "title": "x"]))
        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.absoluteString, "https://tracker.example.com/api/v1/changes")
    }

    func testTheChangesURLSwapsTheTrailingEventsSegment() {
        let config = Configuration()
        config.dsn = "https://key@tracker.example.com/api/v1/events"
        XCTAssertEqual(config.changesURL?.absoluteString, "https://tracker.example.com/api/v1/changes")
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
