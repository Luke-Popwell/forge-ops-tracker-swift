import Foundation

/// Redacts likely-sensitive content out of a payload before it ever leaves the device: the same
/// patterns ForgeOps itself applies again on arrival (defense in depth: this layer keeps the data
/// out of the crash report file on disk and off the wire; the server-side layer is what actually
/// protects the database). Ported from `app/services/pii_scrubber.rb` and this repo's own
/// Objective-C client (`sdks/objc/Sources/ForgeOpsTracker/FOTPiiScrubber.m`): same key list,
/// same 8 regex patterns (`NSRegularExpression`, not Swift's own native `Regex`, specifically so
/// this reuses syntax already verified against real matching input by that client rather than
/// re-verifying a second regex engine's interpretation of the same 8 patterns), same
/// "[LABEL FILTERED]" replacement format. Deliberately does NOT support
/// `Project#additional_sensitive_keys`: confirmed server-side only, see that file's own header
/// comment: extending the pattern list to arbitrary customer regexes is a ReDoS risk best kept
/// out of every client.
public enum PiiScrubber {
    public static let redacted = "[FILTERED]"

    private static let sensitiveKeys: [String] = [
        "password", "passwd", "pwd",
        "secret", "apisecret", "clientsecret", "secretkey",
        "token", "accesstoken", "refreshtoken", "apikey", "apitoken", "authorization", "authtoken", "bearer", "sessiontoken", "csrftoken",
        "creditcard", "cardnumber", "cardnum", "cvv", "cvv2", "cvc",
        "ssn", "socialsecuritynumber", "socialsecurity",
        "privatekey",
    ]

    private struct Pattern {
        let label: String
        let regex: NSRegularExpression
    }

    private static let patterns: [Pattern] = [
        makePattern("EMAIL", #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#),
        makePattern("SSN", #"\b\d{3}-\d{2}-\d{4}\b"#),
        makePattern("CREDIT CARD", #"\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,4}\b"#),
        makePattern("BEARER TOKEN", #"\bBearer\s+[A-Za-z0-9\-._~+/]+=*"#, options: [.caseInsensitive]),
        makePattern("JWT", #"\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#),
        makePattern("AWS KEY", #"\bAKIA[0-9A-Z]{16}\b"#),
        makePattern("STRIPE KEY", #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}\b"#),
        makePattern("GITHUB TOKEN", #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
    ]

    private static func makePattern(_ label: String, _ pattern: String, options: NSRegularExpression.Options = []) -> Pattern {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            fatalError("failed to compile PII pattern \(label)")
        }
        return Pattern(label: label, regex: regex)
    }

    /// `value` may be a `String`, `[String: Any]`, `[Any]`, or anything else (passed through
    /// unchanged). `key` is the enclosing dictionary key `value` was found under (nil for a bare
    /// top-level value or an array element), and is what the key-name check runs against.
    public static func scrub(_ value: Any?, key: String?) -> Any? {
        if value != nil, isSensitiveKey(key) {
            return redacted
        }

        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = scrub(v, key: k)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { scrub($0, key: key) as Any }
        }
        if let string = value as? String {
            return scrubString(string)
        }
        return value
    }

    public static func scrubString(_ string: String) -> String {
        var result = string
        for pattern in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = NSRegularExpression.escapedTemplate(for: "[\(pattern.label) FILTERED]")
            result = pattern.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    private static func isSensitiveKey(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        let normalized = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return sensitiveKeys.contains { normalized.contains($0) }
    }
}
