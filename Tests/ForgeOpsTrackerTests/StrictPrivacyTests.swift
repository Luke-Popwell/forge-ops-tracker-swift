import CFOTTestSupport
@testable import ForgeOpsTracker
import XCTest

final class StrictPrivacyTests: XCTestCase {
    // A database wrapper's error: SqlStatement reads the statement off its `sql` property.
    private struct DatabaseFailure: LocalizedError {
        let sql: String
        let errorDescription: String?
    }

    // Fixtures/strict_privacy_vectors.json is kept byte-identical to sdks/strict_privacy_vectors.json,
    // which the server's own implementation generates.
    private func vectors() throws -> [String: [[String: String]]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "strict_privacy_vectors", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]])
    }

    private func strictConfiguration(allowedFields: [String] = []) -> Configuration {
        let config = Configuration()
        config.environment = "production"
        config.releaseVersion = "a1b2c3d"
        config.serverName = "test-host"
        config.strictPrivacy = true
        config.privacyAllowedFields = allowedFields
        return config
    }

    // MARK: vectors

    func testEveryFingerprintVectorNormalizesAndHashesExactlyAsTheServerDoes() throws {
        let entries = try XCTUnwrap(vectors()["fingerprint"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let message = try XCTUnwrap(entry["message"])
            XCTAssertEqual(StrictPrivacy.normalizeMessage(message), entry["normalized"], "normalized: \(message)")
            XCTAssertEqual(StrictPrivacy.messageFingerprint(message), entry["fingerprint"], "fingerprint: \(message)")
        }
    }

    func testEveryPathVectorHasItsIdsStripped() throws {
        let entries = try XCTUnwrap(vectors()["path"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let path = try XCTUnwrap(entry["path"])
            XCTAssertEqual(StrictPrivacy.pathWithoutIds(path), entry["strict"], "path: \(path)")
        }
    }

    func testEverySpanNameVectorKeepsOnlyTheMethodAndHost() throws {
        let entries = try XCTUnwrap(vectors()["span_name"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let name = try XCTUnwrap(entry["name"])
            XCTAssertEqual(StrictPrivacy.spanName(name), entry["strict"], "span name: \(name)")
        }
    }

    func testATransactionNameKeepsARouteAndStripsIdsFromARawPath() {
        XCTAssertEqual(StrictPrivacy.transactionName("OrdersController#create"), "OrdersController#create")
        XCTAssertEqual(StrictPrivacy.transactionName("load-user"), "load-user")
        XCTAssertEqual(StrictPrivacy.transactionName("GET /users/:id"), "GET /users/:id")
        XCTAssertEqual(StrictPrivacy.transactionName("GET /users/42"), "GET /users/:id")
        XCTAssertEqual(StrictPrivacy.transactionName("/users/42"), "/users/:id")
        XCTAssertEqual(StrictPrivacy.transactionName(""), "")
    }

    func testAnAddressNoURLParserAcceptsStillOnlySendsItsHost() {
        XCTAssertEqual(StrictPrivacy.hostOf("https://api.example.com/pat<ients/jane"), "api.example.com")
        XCTAssertEqual(StrictPrivacy.hostOf("a@b@example.com/x"), "example.com")
        XCTAssertNil(StrictPrivacy.hostOf("patients/42"))
        XCTAssertNil(StrictPrivacy.hostOf("https://"))
    }

    func testAnAbsentMessageFingerprintsAsTheEmptyString() {
        XCTAssertEqual(StrictPrivacy.messageFingerprint(nil), StrictPrivacy.messageFingerprint(""))
        XCTAssertEqual(StrictPrivacy.messageFingerprint(nil), "e3b0c44298fc1c149afbf4c8996fb924")
    }

    func testPathsDropTrailingEmptySegmentsTheWayTheServerDoes() {
        XCTAssertEqual(StrictPrivacy.pathWithoutIds("/a/"), "/a")
        XCTAssertEqual(StrictPrivacy.pathWithoutIds("?q=jane"), "/")
        XCTAssertEqual(StrictPrivacy.pathWithoutIds("/orders/7/items/"), "/orders/:id/items")
    }

    // MARK: configuration

    func testStrictPrivacyIsOffWithNoAllowedFieldsByDefault() {
        let config = Configuration()
        XCTAssertFalse(config.strictPrivacy)
        XCTAssertEqual(config.privacyAllowedFields, [])
    }

    // MARK: error events

    func testAStrictEventCarriesNoFreeText() throws {
        let config = strictConfiguration(allowedFields: ["error_code", "retries", "nested", "flag"])
        config.captureSqlStatement = true
        let error = DatabaseFailure(sql: "SELECT * FROM patients WHERE name = 'Jane'", errorDescription: "Couldn't find patient 8821 (jane@example.com)")

        let event = EventBuilder.buildEvent(
            error: error,
            configuration: config,
            context: ["error_code": "E42", "retries": 3, "flag": true, "nested": ["a": 1], "diagnosis": "flu"],
            user: ["id": 42, "email": "jane@example.com", "username": "jane"],
            breadcrumbs: [["category": "ui", "message": "opened Jane's chart", "level": "info", "timestamp": "2026-10-20T00:00:00Z", "data": [:]]],
            traceId: "0af7651916cd43dd8448eb211c80319c"
        )

        XCTAssertNil(event["message"])
        XCTAssertNil(event["breadcrumbs"])
        XCTAssertNil(event["endpoint"])
        XCTAssertNil(event["sql_statement"])
        XCTAssertNotNil(event["sql_objects"], "table names are kept")
        XCTAssertNil(event["tags"])
        let fingerprint = try XCTUnwrap(event["message_fingerprint"] as? String)
        XCTAssertNotNil(fingerprint.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        // Taken from the message as it would otherwise have been sent: after PII scrubbing.
        XCTAssertEqual(fingerprint, StrictPrivacy.messageFingerprint("Couldn't find patient 8821 ([EMAIL FILTERED])"))

        let context = try XCTUnwrap(event["context"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), ["error_code", "retries", "flag"])
        XCTAssertEqual(context["error_code"] as? String, "E42")
        XCTAssertEqual(context["retries"] as? Int, 3)
        XCTAssertEqual(context["flag"] as? Bool, true)

        let user = try XCTUnwrap(event["user"] as? [String: Any])
        XCTAssertEqual(user.count, 1)
        XCTAssertEqual(user["id"] as? String, "42")

        let backtrace = try XCTUnwrap(event["backtrace"] as? [[String: Any]])
        for frame in backtrace {
            XCTAssertNil(frame["context_line"])
            XCTAssertNil(frame["pre_context"])
            XCTAssertNil(frame["post_context"])
        }
        // Structured facts are kept exactly.
        XCTAssertEqual(event["exception_class"] as? String, "DatabaseFailure")
        XCTAssertEqual(event["environment"] as? String, "production")
        XCTAssertEqual(event["release"] as? String, "a1b2c3d")
        XCTAssertEqual(event["server_name"] as? String, "test-host")
        XCTAssertEqual(event["trace_id"] as? String, "0af7651916cd43dd8448eb211c80319c")
        XCTAssertEqual(event["sdk_name"] as? String, "swift")
    }

    func testAStrictExceptionEventGroupsByItsFingerprint() throws {
        let config = strictConfiguration()
        let exception = FOTRaiseAndCatchTestException("TestException", "Order 8821 failed")

        let event = EventBuilder.buildEvent(exception: exception, configuration: config, context: ["order_id": 8821])

        XCTAssertNil(event["message"])
        XCTAssertNil(event["context"], "no allowed fields means no context at all")
        XCTAssertNil(event["user"])
        XCTAssertEqual(event["message_fingerprint"] as? String, StrictPrivacy.messageFingerprint("Order 9004 failed"))
        XCTAssertEqual(event["exception_class"] as? String, "TestException")
    }

    func testAUserWithNoIdIsLeftOutAndAStringIdIsKept() {
        let config = strictConfiguration()
        let error = NSError(domain: "Test", code: 1)

        let noId = EventBuilder.buildEvent(error: error, configuration: config, context: nil, user: ["email": "jane@example.com"])
        XCTAssertNil(noId["user"])

        let withId = EventBuilder.buildEvent(error: error, configuration: config, context: nil, user: ["id": "u_1", "username": "jane"])
        XCTAssertEqual((withId["user"] as? [String: Any])?["id"] as? String, "u_1")
        XCTAssertEqual((withId["user"] as? [String: Any])?.count, 1)
    }

    func testApplyingTheRulesTwiceKeepsTheFirstFingerprint() {
        let once = StrictPrivacy.event(["message": "boom 1", "exception_class": "E"], allowedFields: [])
        let twice = StrictPrivacy.event(once, allowedFields: [])
        XCTAssertEqual(twice["message_fingerprint"] as? String, StrictPrivacy.messageFingerprint("boom 1"))
        XCTAssertNil(twice["message"])
    }

    func testARawSignalReportIsReducedBeforeUpload() throws {
        let payload = try XCTUnwrap(writeAndParseRawSignalReport())
        let event = StrictPrivacy.event(payload, allowedFields: [])
        XCTAssertNil(event["message"])
        XCTAssertEqual(event["message_fingerprint"] as? String, StrictPrivacy.messageFingerprint("Uncaught fatal signal: SIGSEGV"))
        XCTAssertEqual(event["exception_class"] as? String, "Signal: SIGSEGV")
    }

    private func writeAndParseRawSignalReport() throws -> [String: Any]? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".txt")
        try "SIGSEGV\n0 libsystem 0x1 frame\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return SignalHandler.parseRawSignalReport(at: url)
    }

    func testWithStrictPrivacyOffAnEventIsExactlyAsBefore() throws {
        let config = Configuration()
        config.releaseVersion = "a1b2c3d"
        config.serverName = "test-host"
        config.captureSqlStatement = true
        config.privacyAllowedFields = ["error_code"] // ignored while strict privacy is off
        let error = DatabaseFailure(sql: "SELECT * FROM patients WHERE id = 8821", errorDescription: "Couldn't find patient 8821")

        let event = EventBuilder.buildEvent(
            error: error,
            configuration: config,
            context: ["error_code": "E42", "diagnosis": "flu"],
            user: ["id": 42, "email": "jane@example.com"],
            breadcrumbs: [["category": "ui", "message": "opened chart", "level": "info", "timestamp": "2026-10-20T00:00:00Z", "data": [:]]]
        )

        XCTAssertEqual(
            Set(event.keys),
            ["exception_class", "message", "backtrace", "occurred_at", "environment", "release", "server_name", "context", "tags", "sdk_name", "breadcrumbs", "sql_objects", "sql_statement", "user"]
        )
        XCTAssertEqual(event["message"] as? String, "Couldn't find patient 8821")
        XCTAssertNil(event["message_fingerprint"])
        XCTAssertEqual((event["context"] as? [String: Any])?.count, 2)
        XCTAssertEqual((event["user"] as? [String: Any])?["email"] as? String, "jane@example.com")
        XCTAssertEqual((event["user"] as? [String: Any])?["id"] as? Int, 42)
        XCTAssertEqual(event["sql_statement"] as? String, "SELECT * FROM patients WHERE id = ?")
        XCTAssertEqual((event["breadcrumbs"] as? [[String: Any]])?.count, 1)
    }

    // MARK: breadcrumbs

    func testNoBreadcrumbIsRecordedUnderStrictPrivacy() {
        let config = strictConfiguration()
        config.crashReportsDirectory = NSTemporaryDirectory() + UUID().uuidString
        let buffer = BreadcrumbBuffer(configuration: config)

        buffer.add(message: "opened Jane's chart", category: "ui", level: "info", data: [:])

        XCTAssertTrue(buffer.all().isEmpty)
    }

    // MARK: spans

    private func finishedTrace(strict: Bool, _ body: (Trace) -> Void) throws -> [[String: Any]] {
        let config = strict ? strictConfiguration() : Configuration()
        config.traceCaptureThreshold = 0
        var delivered: [String: Any]?
        let trace = Trace(name: "GET /patients/42/notes", configuration: config) { delivered = $0 }
        body(trace)
        trace.finish()
        return try XCTUnwrap(delivered?["spans"] as? [[String: Any]])
    }

    private func span(_ kind: String, in spans: [[String: Any]]) -> [String: Any]? {
        spans.first { $0["kind"] as? String == kind }
    }

    func testStrictSpansKeepOnlyTheMethodAndHostAndTheDatabaseFields() throws {
        let spans = try finishedTrace(strict: true) { trace in
            var request = URLRequest(url: URL(string: "https://api.example.com/patients/42?name=jane")!)
            request.httpMethod = "POST"
            trace.startRequestSpan(request, name: "POST https://api.example.com/patients/42?name=jane")
                .finish(response: HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil))
            trace.recordSpan("SELECT patients", kind: "database", startedAt: Date(), durationMs: 2,
                             data: ["row_count": 1, "patient": "Jane"], statement: "SELECT * FROM patients WHERE id = 42", dbSystem: "SQLite")
            trace.recordSpan("render", startedAt: Date(), durationMs: 1, data: ["patient": "Jane"])
        }

        let root = try XCTUnwrap(span("controller", in: spans))
        XCTAssertEqual(root["name"] as? String, "GET /patients/:id/notes")

        let http = try XCTUnwrap(span("http", in: spans))
        XCTAssertEqual(http["name"] as? String, "POST api.example.com")
        XCTAssertEqual((http["data"] as? [String: Any])?.count, 0)

        let database = try XCTUnwrap(span("database", in: spans))
        XCTAssertEqual(database["name"] as? String, "SELECT patients")
        let data = try XCTUnwrap(database["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["db.statement", "db.system"])
        XCTAssertEqual(data["db.statement"] as? String, "SELECT * FROM patients WHERE id = ?")
        XCTAssertEqual(data["db.system"] as? String, "sqlite")

        let service = try XCTUnwrap(span("service", in: spans))
        XCTAssertEqual((service["data"] as? [String: Any])?.count, 0)
    }

    func testWithStrictPrivacyOffSpansAreExactlyAsBefore() throws {
        let spans = try finishedTrace(strict: false) { trace in
            let request = URLRequest(url: URL(string: "https://api.example.com/patients/42")!)
            trace.startRequestSpan(request, name: "GET https://api.example.com/patients/42")
                .finish(response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            trace.recordSpan("render", startedAt: Date(), durationMs: 1, data: ["patient": "Jane"])
        }

        XCTAssertEqual(span("controller", in: spans)?["name"] as? String, "GET /patients/42/notes")
        let http = try XCTUnwrap(span("http", in: spans))
        XCTAssertEqual(http["name"] as? String, "GET https://api.example.com/patients/42")
        XCTAssertEqual((http["data"] as? [String: Any])?["status"] as? Int, 200)
        XCTAssertEqual((span("service", in: spans)?["data"] as? [String: Any])?["patient"] as? String, "Jane")
    }
}
