@testable import ForgeOpsTracker
import XCTest

final class SqlStatementTests: XCTestCase {
    /// Stands in for GRDB's DatabaseError, which exposes the statement as a stored `sql` property.
    private struct FakeDatabaseError: Error {
        let message: String
        let sql: String?
    }

    private func configuration(objects: Bool = true, statement: Bool = false) -> Configuration {
        let config = Configuration()
        config.environment = "production"
        config.captureSqlObjects = objects
        config.captureSqlStatement = statement
        return config
    }

    func testFindsTheStatementOffAPropertyOnTheErrorValue() {
        XCTAssertEqual(SqlStatement.findIn(error: FakeDatabaseError(message: "boom", sql: "SELECT 1")), "SELECT 1")
        XCTAssertNil(SqlStatement.findIn(error: FakeDatabaseError(message: "boom", sql: nil)))
    }

    func testReadsTheStatementOutOfGrdbAndSqliteErrorText() {
        XCTAssertEqual(SqlStatement.findIn(text: "SQLite error 1: no such table: t - while executing `SELECT * FROM t`"), "SELECT * FROM t")
        XCTAssertEqual(
            SqlStatement.findIn(text: "no such table: notes (code 1 SQLITE_ERROR): , while compiling: SELECT * FROM notes WHERE id = 42"),
            "SELECT * FROM notes WHERE id = 42"
        )
        XCTAssertNil(SqlStatement.findIn(text: "just a plain error"))
    }

    func testFollowsTheUnderlyingError() {
        let inner = NSError(domain: "db", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad - while executing `SELECT 2`"])
        let outer = NSError(domain: "app", code: 2, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertEqual(SqlStatement.findIn(error: outer), "SELECT 2")
    }

    func testMasksStringsAndNumbersButNotIdentifiersOrPlaceholders() {
        XCTAssertEqual(
            SqlStatement.mask("SELECT * FROM orders2 WHERE email = 'a@b.co' AND id = 42 AND x = $1"),
            "SELECT * FROM orders2 WHERE email = ? AND id = ? AND x = $1"
        )
        XCTAssertEqual(SqlStatement.mask("SELECT price * 1.5 FROM t"), "SELECT price * ? FROM t")
    }

    func testMasksAnEscapedQuoteACutOffStringAndADollarQuotedBody() {
        XCTAssertEqual(SqlStatement.mask("EXEC sp_x @t = 'it''s'"), "EXEC sp_x @t = ?")
        XCTAssertEqual(SqlStatement.mask("SELECT 1 WHERE n = 'oops"), "SELECT ? WHERE n = ?")
        XCTAssertEqual(SqlStatement.mask("DO $b$ BEGIN PERFORM 1; END $b$"), "DO ?")
    }

    func testIsIdempotentTruncatesAndReturnsNilForBlank() {
        let once = SqlStatement.mask("SELECT * FROM t WHERE a = 'x' AND b = 9")
        XCTAssertEqual(SqlStatement.mask(once), once)
        XCTAssertEqual(SqlStatement.mask("SELECT " + String(repeating: "a, ", count: 3000) + " b")?.count, SqlStatement.maxLength + 3)
        XCTAssertNil(SqlStatement.mask("  "))
        XCTAssertNil(SqlStatement.mask(nil))
    }

    /// The shared masking corpus: the same cases, with the same expected output, are checked in every
    /// SDK and against the server's SqlStatementMasker.
    private static let corpus: [(input: String, system: String?, expected: String)] = [
        ("SELECT * FROM orders WHERE email = 'a@b.co' AND id = 42 LIMIT 10", nil, "SELECT * FROM orders WHERE email = ? AND id = ? LIMIT ?"),
        ("EXEC sp_note @text = 'it''s broken'", nil, "EXEC sp_note @text = ?"),
        ("SELECT 1 WHERE name = 'unterminated", nil, "SELECT ? WHERE name = ?"),
        ("DO $body$ BEGIN PERFORM 1; END $body$", nil, "DO ?"),
        ("SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)", nil, "SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)"),
        ("SELECT price * 1.5 FROM t", nil, "SELECT price * ? FROM t"),
        ("SELECT * FROM users WHERE name = E'o\\'brien' AND id = 1", nil, "SELECT * FROM users WHERE name = ? AND id = ?"),
        ("SELECT * FROM users WHERE name = 'o\\'brien' AND id = 1", nil, "SELECT * FROM users WHERE name = ? AND id = ?"),
        ("SELECT * FROM t WHERE b = X'DEADBEEF' AND s = N'uni' AND u = U&'d\\0061t' AND e = e'x'", nil, "SELECT * FROM t WHERE b = ? AND s = ? AND u = ? AND e = ?"),
        ("SELECT * FROM t WHERE a LIKE'%secret%'", nil, "SELECT * FROM t WHERE a LIKE?"),
        ("SELECT * FROM t WHERE f = 0x1F AND b = 0b101 AND n = 3e10 AND m = 1.5E-3 AND k = .5", nil, "SELECT * FROM t WHERE f = ? AND b = ? AND n = ? AND m = ? AND k = ?"),
        ("SELECT e, t.col, 1e5e FROM t", nil, "SELECT e, t.col, 1e5e FROM t"),
        ("SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "mysql", "SELECT ? FROM t WHERE token = ?"),
        ("SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "MariaDB", "SELECT ? FROM t WHERE token = ?"),
        ("SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "postgresql", "SELECT \"user id\" FROM t WHERE token = \"abc123secret\""),
        ("SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", nil, "SELECT \"user id\" FROM t WHERE token = \"abc123secret\""),
        ("SELECT * FROM t WHERE a = 'x' AND b = 9", nil, "SELECT * FROM t WHERE a = ? AND b = ?"),
        ("SELECT * FROM t WHERE a = ? AND b = ?", nil, "SELECT * FROM t WHERE a = ? AND b = ?"),
        ("SELECT * FROM t WHERE path = 'C:\\\\dir\\\\' AND n = 5", nil, "SELECT * FROM t WHERE path = ? AND n = ?"),
        ("INSERT INTO t (a, b) VALUES (-5, +3.25e+2)", nil, "INSERT INTO t (a, b) VALUES (-?, +?)"),
        ("SELECT * FROM t WHERE a = 'secret\\", nil, "SELECT * FROM t WHERE a = ?"),
        ("SELECT * FROM t WHERE a = \"secret\\", "mysql", "SELECT * FROM t WHERE a = ?"),
    ]

    func testMasksTheSharedCorpusExactlyLikeTheServer() {
        for (input, system, expected) in Self.corpus {
            XCTAssertEqual(SqlStatement.mask(input, system: system), expected, "\(input) (\(system ?? "nil"))")
            XCTAssertEqual(SqlStatement.mask(expected, system: system), expected, "\(expected) (\(system ?? "nil"))")
        }
    }

    func testFindsAStoredProcedureWithItsSchema() {
        let found = SqlStatement.objects("EXEC dbo.sp_refund_order @id = ?")
        XCTAssertEqual(found?["operation"] as? String, "EXEC")
        XCTAssertEqual(found?["procedures"] as? [String], ["dbo.sp_refund_order"])
        XCTAssertEqual(found?["relations"] as? [String], [])
        XCTAssertEqual(SqlStatement.objects("CALL refund_order(?, ?)")?["procedures"] as? [String], ["refund_order"])
        XCTAssertEqual(SqlStatement.objects("SELECT refund_order(?, ?)")?["procedures"] as? [String], ["refund_order"])
    }

    func testFindsViewsJoinedTablesAndTableFunctions() {
        XCTAssertEqual(
            SqlStatement.objects("SELECT * FROM v_totals t JOIN public.customers c ON c.id = t.id")?["relations"] as? [String],
            ["v_totals", "public.customers"]
        )
        XCTAssertEqual(SqlStatement.objects("SELECT * FROM get_open_orders(?) o")?["procedures"] as? [String], ["get_open_orders"])
    }

    func testDoesNotMisreadColumnListsOrBuiltinsAndReturnsNilForGarbage() {
        XCTAssertEqual(SqlStatement.objects("INSERT INTO audit_log (a) VALUES (?)")?["procedures"] as? [String], [])
        XCTAssertEqual(SqlStatement.objects("SELECT count(*) FROM orders")?["procedures"] as? [String], [])
        XCTAssertNil(SqlStatement.objects("garbage"))
    }

    func testEventBuilderSendsTheTableNameByDefaultAndTheMaskedStatementOnlyWhenOptedIn() {
        let error = FakeDatabaseError(message: "boom", sql: "SELECT * FROM notes WHERE title = 'a@b.co' AND id = 8814")

        let payload = EventBuilder.buildEvent(error: error, configuration: configuration(), context: nil)
        XCTAssertEqual((payload["sql_objects"] as? [String: Any])?["relations"] as? [String], ["notes"])
        XCTAssertNil(payload["sql_statement"])

        let opted = EventBuilder.buildEvent(error: error, configuration: configuration(statement: true), context: nil)
        XCTAssertEqual(opted["sql_statement"] as? String, "SELECT * FROM notes WHERE title = ? AND id = ?")

        let off = EventBuilder.buildEvent(error: error, configuration: configuration(objects: false), context: nil)
        XCTAssertNil(off["sql_objects"])
        XCTAssertNil(off["sql_statement"])
        XCTAssertNil(EventBuilder.buildEvent(error: NSError(domain: "x", code: 1), configuration: configuration(), context: nil)["sql_objects"])
    }
}
