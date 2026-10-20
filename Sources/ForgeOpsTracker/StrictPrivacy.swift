import CryptoKit
import Foundation

/// Strict privacy (`Configuration.strictPrivacy`): for apps that can't let personal or health data
/// leave the device. With it on, only structured facts are sent: an error's type, its frames,
/// release, environment, server, trace id, timings and counts. Free text, which is where personal
/// data hides (an error's message, context and tags outside `privacyAllowedFields`, breadcrumbs,
/// URL paths, the user's email and username), never leaves the process.
///
/// Ported from `app/services/strict_privacy.rb`, the server's own second layer, which applies the
/// same rules again on arrival when the project's own Strict privacy setting is on. The rules are
/// in `sdks/STRICT_PRIVACY.md`, and `sdks/strict_privacy_vectors.json` pins the exact results
/// every SDK must produce (a copy lives in this package's test fixtures).
///
/// Grouping keeps working without the message: `message_fingerprint` is a one-way hash of the
/// message with its numbers and ids taken out, so two messages that differ only in ids hash the same.
enum StrictPrivacy {
    static let fingerprintLength = 32

    // ASCII "word" characters, spelled out rather than \w or \b: NSRegularExpression's own idea of
    // a word includes letters and digits from every script, and the server's doesn't, so "٣" (an
    // Arabic-Indic digit) or "é" next to a number must not stop it being replaced.
    private static let word = "A-Za-z0-9_"
    private static let hexObjectId = regex("0x[0-9a-fA-F]{4,}")
    private static let uuid = regex("(?<![\(word)])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![\(word)])")
    private static let number = regex("(?<![\(word)])[0-9]+(?![\(word)])")

    // Ruby's \s and \S are ASCII whitespace only; ICU's are Unicode, so the class is spelled out.
    private static let httpMethod = regex(#"\A(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)[ \t\r\n\f\u000B]+([^ \t\r\n\f\u000B]+)"#, options: [.caseInsensitive])
    private static let scheme = regex(#"\A[a-z][a-z0-9+.-]*://"#, options: [.caseInsensitive])
    private static let port = regex(#":[0-9]+\z"#)

    /// Span data that's structure, not content: the masked statement and which database it ran on.
    static let spanDataKeys = ["db.statement", "db.system"]

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            fatalError("failed to compile strict privacy regex \(pattern)")
        }
        return regex
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: template)
    }

    /// The message with hex object ids, UUIDs and standalone numbers replaced, in that order.
    static func normalizeMessage(_ message: String?) -> String {
        var result = message ?? ""
        result = replace(hexObjectId, in: result, with: "0x")
        result = replace(uuid, in: result, with: "<uuid>")
        result = replace(number, in: result, with: "<n>")
        return result
    }

    /// First 32 lowercase hex characters of the SHA-256 of the normalized message's UTF-8 bytes.
    static func messageFingerprint(_ message: String?) -> String {
        let digest = SHA256.hash(data: Data(normalizeMessage(message).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(fingerprintLength))
    }

    /// A fingerprint already on a payload, when it's well formed; anything else is ignored.
    private static func validFingerprint(_ value: Any?) -> String? {
        guard let fingerprint = (value as? String)?.lowercased(), fingerprint.count == fingerprintLength,
              fingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return fingerprint
    }

    /// An error event, reduced to what strict privacy sends. Called on the finished payload, after
    /// PII scrubbing, so the fingerprint is taken from the message exactly as it would otherwise
    /// have been sent. Safe to apply twice: a payload that already carries a fingerprint keeps it.
    static func event(_ payload: [String: Any], allowedFields: [String]) -> [String: Any] {
        var result = payload
        result["message_fingerprint"] = validFingerprint(payload["message_fingerprint"]) ?? messageFingerprint(payload["message"] as? String)
        for key in ["message", "breadcrumbs", "sql_statement", "endpoint", "context", "tags", "user"] {
            result[key] = nil
        }
        if let context = allowed(payload["context"], allowedFields: allowedFields) {
            result["context"] = context
        }
        if let tags = allowed(payload["tags"], allowedFields: allowedFields) {
            result["tags"] = tags
        }
        if let user = user(payload["user"]) {
            result["user"] = user
        }
        if let backtrace = payload["backtrace"] as? [[String: Any]] {
            result["backtrace"] = backtrace.map { frame in
                frame.filter { !["context_line", "pre_context", "post_context"].contains($0.key) }
            }
        }
        return result
    }

    /// A trace's span: its name through `spanName`, and only `spanDataKeys` left in its data.
    static func span(name: String, data: [String: Any]?) -> (name: String, data: [String: Any]?) {
        let kept = data?.filter { spanDataKeys.contains($0.key) }
        return (spanName(name), kept)
    }

    /// "GET https://api.example.com/patients/42?x=1" or "GET api.example.com/patients/42" becomes
    /// "GET api.example.com"; a path goes through `strictPath`, alone or after a method:
    /// "GET /patients/42/notes" becomes "GET /patients/:path", "/patients/:id" stays. Any other name ("OrdersController#create") is kept as it is. Read by
    /// hand, never with a URL parser: one that rejects an address must not mean the whole address
    /// is sent.
    static func spanName(_ name: String) -> String {
        if name.hasPrefix("/") { return strictPath(name) }
        guard let match = httpMethod.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let methodRange = Range(match.range(at: 1), in: name),
              let targetRange = Range(match.range(at: 2), in: name) else { return name }

        let method = name[methodRange].uppercased()
        let target = String(name[targetRange])
        if target.hasPrefix("/") { return "\(method) \(strictPath(target))" }
        return "\(method) \(hostOf(target) ?? strictPath(target))"
    }

    /// The host of an outbound call's address: whatever comes before the first "/", "?" or "#",
    /// without a scheme, credentials or port. It's a host when the address had a scheme or a port,
    /// or the name has a dot or is "localhost"; otherwise (a relative path) `nil`.
    static func hostOf(_ target: String) -> String? {
        let hasScheme = scheme.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
        var authority = replace(scheme, in: target, with: "")
        if let cut = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = String(authority[..<cut])
        }
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        let hasPort = port.firstMatch(in: authority, range: NSRange(authority.startIndex..., in: authority)) != nil
        let host = replace(port, in: authority, with: "")
        guard !host.isEmpty else { return nil }
        return hasScheme || hasPort || host.contains(".") || host.lowercased() == "localhost" ? host : nil
    }

    /// Which request something happened in: a route or a name like "load-user" is kept, but a raw
    /// path keeps only its first segment, by the same rule as a span's name. An empty name is kept.
    static func transactionName(_ name: String) -> String {
        name.isEmpty ? name : spanName(name)
    }

    /// A request or page path as strict privacy sends it, with no query or fragment. A route
    /// template (any segment that starts with ":" or "*", or is wrapped in {}, <> or []) is kept as
    /// it is: "/patients/:id/notes" stays. A raw path keeps only its first segment (":id" when that
    /// holds an ASCII digit or is longer than 40 characters), then "/:path" if there was more:
    /// "/patients/jane-doe/12" is "/patients/:path", "/42/edit" is "/:id/:path". No segments is "/".
    static func strictPath(_ path: String) -> String {
        let cut = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let bare = cut.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let all = bare.components(separatedBy: "/")
        if all.contains(where: isRouteParameter) { return bare }

        let segments = all.filter { !$0.isEmpty }
        guard let first = segments.first else { return "/" }
        let hasDigit = first.unicodeScalars.contains { ("0" ... "9").contains($0) }
        let head = hasDigit || first.unicodeScalars.count > 40 ? ":id" : first
        return (bare.hasPrefix("/") ? "/" : "") + head + (segments.count > 1 ? "/:path" : "")
    }

    /// ":id", "{id}", "<int:id>", "[slug]" or "*path": a parameter with a name (anything after
    /// "*"), and no newline in it, the same as the server's ".".
    private static func isRouteParameter(_ segment: String) -> Bool {
        let scalars = Array(segment.unicodeScalars)
        guard !scalars.contains("\n"), let first = scalars.first else { return false }
        if first == "*" { return true }
        if first == ":" { return scalars.count >= 2 }
        guard scalars.count >= 3, let last = scalars.last else { return false }
        return (first == "{" && last == "}") || (first == "<" && last == ">") || (first == "[" && last == "]")
    }

    /// Only the allowed top-level keys, and only plain values (a string, number or boolean, which
    /// all bridge to `NSNumber`); `nil` when nothing is left.
    private static func allowed(_ fields: Any?, allowedFields: [String]) -> [String: Any]? {
        guard !allowedFields.isEmpty, let fields = fields as? [String: Any] else { return nil }
        let kept = fields.filter { key, value in
            allowedFields.contains(key) && (value is String || value is NSNumber)
        }
        return kept.isEmpty ? nil : kept
    }

    /// The user's id only, as a string; `nil` when there's no id.
    private static func user(_ user: Any?) -> [String: Any]? {
        guard let user = user as? [String: Any], let id = user["id"], !(id is NSNull) else { return nil }
        let string = (id as? String) ?? "\(id)"
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ["id": string]
    }
}
