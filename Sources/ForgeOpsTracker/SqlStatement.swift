import Foundation

/// Finds the SQL behind a database error and reduces it to something safe to send: the names of
/// the stored procedures, tables and views it touched, and (only if
/// `Configuration.captureSqlStatement` is on) the statement itself with every string and number
/// replaced by `?`. Ported from `gems/forge_ops_tracker`'s `SqlStatement`, which is itself ported
/// from the server's own `SqlStatementMasker`/`SqlObjectExtractor`: same rules everywhere, and the
/// server applies them again on arrival, so a difference here can only ever mean less is masked
/// client-side, never that something unmasked gets stored.
///
/// Deliberately a single pass over a few patterns, not a SQL parser. On Apple platforms the SQL
/// comes from a local SQLite database, so the two sources are a property on the error value
/// itself (GRDB's `DatabaseError.sql`, found by reflection so this client never depends on GRDB)
/// and SQLite's own error text (`while executing ...` from GRDB, `while compiling: ...` from
/// SQLite itself). Core Data exposes neither, so an error from it simply has no statement to find.
enum SqlStatement {
    static let mask = "?"
    static let maxLength = 4000
    private static let maxNames = 10
    private static let maxNameLength = 200
    private static let maxCauseDepth = 5

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            fatalError("failed to compile SQL pattern: \(pattern)")
        }
        return compiled
    }

    private static let literal = regex(
        #"'(?:[^']|'')*(?:'|\z)|(\$[A-Za-z_]*\$).*?(?:\1|\z)|(?<![\w$.])\d+(?:\.\d+)?(?!\w)"#,
        [.dotMatchesLineSeparators]
    )

    private static let part = #"(?:[\w$#@]+|"[^"]+"|\[[^\]]+\]|`[^`]+`)"#
    private static let name = part + #"(?:\."# + part + ")*"
    private static let operations: Set<String> = ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "WITH", "CALL", "EXEC", "EXECUTE", "CREATE", "ALTER", "DROP", "TRUNCATE"]
    private static let procedureCall = regex(#"\b(?:CALL|EXEC(?:UTE)?|PERFORM)\s+(?!IMMEDIATE\b|FUNCTION\b|PROCEDURE\b)("# + name + ")", [.caseInsensitive])
    private static let relation = regex(#"\b(FROM|JOIN|INTO|UPDATE|TABLE)\s+("# + name + #")(\s*\()?"#, [.caseInsensitive])
    private static let selectFunction = regex(#"\A\s*SELECT\s+("# + name + #")\s*\("#, [.caseInsensitive])
    private static let builtins: Set<String> = [
        "count", "sum", "min", "max", "avg", "now", "coalesce", "nullif", "lower", "upper", "length", "concat",
        "cast", "date_trunc", "current_timestamp", "current_date", "row_number", "rank", "json_build_object",
        "json_agg", "array_agg",
    ]
    private static let fromInsideFunction = regex(#"\b(?:EXTRACT|SUBSTRING|TRIM|OVERLAY)\s*\([^()]*\)"#, [.caseInsensitive])
    private static let keywordsNotNames: Set<String> = ["select", "set", "values", "where", "lateral", "only", "unnest", "generate_series"]
    private static let fullName = regex(#"\A"# + name + #"\z"#)
    private static let fromWord = regex(#"\bFROM\b"#, [.caseInsensitive])
    private static let firstWord = regex(#"\A\s*(\w+)"#)

    // GRDB's error description ends "... - while executing `SELECT ...`"; SQLite's own text ends
    // "..., while compiling: SELECT ...". Best-effort by nature.
    private static let grdbExecuting = regex(#"while executing `(.*)`"#, [.dotMatchesLineSeparators])
    private static let sqliteCompiling = regex(#"while compiling:\s*(.+?)\s*\z"#, [.dotMatchesLineSeparators])

    /// Property names database wrappers put the failing statement on, read by reflection.
    private static let statementProperties: Set<String> = ["sql", "statement", "query", "causingStatement"]

    // MARK: - Finding

    /// The raw statement off the error itself or, for an app that wraps a database error in its
    /// own, off whatever it was raised from (`NSUnderlyingErrorKey`).
    static func findIn(error: Error?) -> String? {
        var current: Error? = error
        var depth = 0
        while let candidate = current, depth < maxCauseDepth {
            if let statement = statement(ofValue: candidate) { return statement }
            if let statement = findIn(text: (candidate as NSError).localizedDescription) { return statement }
            // A plain NSError's description embeds its whole underlying-error chain in one string,
            // which a greedy pattern would swallow; its localizedDescription above already covers
            // it, and the loop below reaches the underlying error on its own.
            if !(type(of: candidate) is NSError.Type), let statement = findIn(text: String(describing: candidate)) {
                return statement
            }
            current = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return nil
    }

    static func findIn(exception: NSException) -> String? {
        exception.reason.flatMap { findIn(text: $0) }
    }

    static func findIn(text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in [grdbExecuting, sqliteCompiling] {
            if let match = pattern.firstMatch(in: text, options: [], range: range),
               let captured = Range(match.range(at: 1), in: text) {
                let statement = String(text[captured])
                if !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return statement }
            }
        }
        return nil
    }

    private static func statement(ofValue value: Any) -> String? {
        for child in Mirror(reflecting: value).children {
            guard let label = child.label, statementProperties.contains(label) else { continue }
            if let statement = child.value as? String,
               !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return statement
            }
        }
        return nil
    }

    // MARK: - Masking

    static func mask(_ statement: String?) -> String? {
        guard let statement, !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let range = NSRange(statement.startIndex..., in: statement)
        let masked = literal.stringByReplacingMatches(in: statement, options: [], range: range, withTemplate: mask)
        return masked.count > maxLength ? String(masked.prefix(maxLength)) + "..." : masked
    }

    // MARK: - Objects

    /// Takes an already-masked statement (so a keyword inside a string value can't be mistaken for
    /// SQL). Returns `nil` when nothing recognizable was found.
    static func objects(_ masked: String?) -> [String: Any]? {
        guard let masked, !masked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let sql = fromInsideFunction.stringByReplacingMatches(
            in: masked, options: [], range: NSRange(masked.startIndex..., in: masked), withTemplate: " "
        )
        let full = NSRange(sql.startIndex..., in: sql)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Range(range, in: sql).map { String(sql[$0]) }
        }

        var procedures = procedureCall.matches(in: sql, options: [], range: full).compactMap { group($0, 1) }
        var relations: [String] = []

        for match in relation.matches(in: sql, options: [], range: full) {
            guard let keyword = group(match, 1), let name = group(match, 2) else { continue }
            if keywordsNotNames.contains(name.lowercased()) { continue }
            let isFunctionCall = (group(match, 3) ?? "").isEmpty == false && ["FROM", "JOIN"].contains(keyword.uppercased())
            if isFunctionCall { procedures.append(name) } else { relations.append(name) }
        }

        if let match = selectFunction.firstMatch(in: sql, options: [], range: full),
           let function = group(match, 1),
           !builtins.contains(function.lowercased()),
           fromWord.firstMatch(in: sql, options: [], range: full) == nil {
            procedures.append(function)
        }

        let operation = firstWord.firstMatch(in: sql, options: [], range: full).flatMap { group($0, 1) }?.uppercased() ?? ""
        var result: [String: Any] = [:]
        if operations.contains(operation) { result["operation"] = operation }
        let cleanProcedures = clean(procedures)
        let cleanRelations = clean(relations)
        result["procedures"] = cleanProcedures
        result["relations"] = cleanRelations
        if cleanProcedures.isEmpty, cleanRelations.isEmpty, result["operation"] == nil { return nil }
        return result
    }

    private static func clean(_ names: [String]) -> [String] {
        var cleaned: [String] = []
        for raw in names {
            let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            let range = NSRange(name.startIndex..., in: name)
            if fullName.firstMatch(in: name, options: [], range: range) != nil, !cleaned.contains(name) {
                cleaned.append(name)
            }
        }
        return Array(cleaned.prefix(maxNames))
    }
}
