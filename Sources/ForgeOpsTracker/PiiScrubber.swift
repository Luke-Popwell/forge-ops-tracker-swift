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
        "iban", "accountnumber", "routingnumber", "bankaccount",
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

    // Card numbers in any other shape, and IBANs: see sdks/PII_SCRUBBING.md, which every SDK
    // follows, and sdks/pii_scrubbing_vectors.json (a copy is in Tests/ForgeOpsTrackerTests/Fixtures),
    // which pins the results. Word characters and digits are spelled out as ASCII classes: ICU's
    // own \w, \d and \b are Unicode-aware, and the rule is ASCII only.
    private static let digitRun = makePattern("DIGIT RUN", #"(?<![A-Za-z0-9_])[0-9](?:[ -]?[0-9])*(?![A-Za-z0-9_])"#).regex
    private static let cardPrefixes = makePattern(
        "CARD PREFIXES",
        #"\A(?:4|5[1-5]|2(?:22[1-9]|2[3-9][0-9]|[3-6][0-9][0-9]|7[01][0-9]|720)|3[47]|6011|64[4-9]|65|35(?:2[89]|[3-8][0-9])|36|30[0-5]|62)"#
    ).regex
    private static let iban = makePattern(
        "IBAN",
        #"(?<![A-Za-z0-9_])[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)(?![A-Za-z0-9_])"#
    ).regex

    public static func scrubString(_ string: String) -> String {
        // IBANs first: a spaced IBAN's middle groups look like a formatted card number.
        var result = replaceMatches(of: iban, in: string) { isIban($0) ? "[IBAN FILTERED]" : $0 }
        for pattern in patterns {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = NSRegularExpression.escapedTemplate(for: "[\(pattern.label) FILTERED]")
            result = pattern.regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return replaceMatches(of: digitRun, in: result, with: scrubCardNumbers(in:))
    }

    /// Every match of `regex` replaced by `transform` of its text. Positions are NSString (UTF-16)
    /// offsets throughout, the same ones `NSRegularExpression` reports.
    private static func replaceMatches(of regex: NSRegularExpression, in string: String, with transform: (String) -> String) -> String {
        let text = string as NSString
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        var output = ""
        var cursor = 0
        for match in regex.matches(in: string, options: [], range: range) {
            output += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += transform(text.substring(with: match.range))
            cursor = NSMaxRange(match.range)
        }
        output += text.substring(from: cursor)
        return output
    }

    /// From each group of the run on, the longest stretch of whole groups that is a card number is
    /// replaced, so a card followed by its CVV, two cards in a row, and Amex's 4-6-5 are all found.
    private static func scrubCardNumbers(in run: String) -> String {
        var digits: [String] = [""]
        var separators: [String] = []
        for character in run {
            if character == " " || character == "-" {
                separators.append(String(character))
                digits.append("")
            } else {
                digits[digits.count - 1].append(character)
            }
        }
        separators.append("")

        var output = ""
        var i = 0
        while i < digits.count {
            if let last = stride(from: digits.count - 1, through: i, by: -1).first(where: { isCardNumber(digits[i...$0].joined()) }) {
                output += "[CREDIT CARD FILTERED]" + separators[last]
                i = last + 1
            } else {
                output += digits[i] + separators[i]
                i += 1
            }
        }
        return output
    }

    private static func isCardNumber(_ digits: String) -> Bool {
        let range = NSRange(digits.startIndex..<digits.endIndex, in: digits)
        return (13...19).contains(digits.count)
            && cardPrefixes.firstMatch(in: digits, options: [], range: range) != nil
            && passesLuhn(digits)
    }

    private static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, byte) in digits.utf8.reversed().enumerated() {
            var value = Int(byte) - 48
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    /// The IBAN check, a digit at a time: the first four characters moved to the end, letters as
    /// two digits (A is 10), and the remainder by 97 is 1.
    private static func isIban(_ candidate: String) -> Bool {
        let compact = Array(candidate.utf8.filter { $0 != UInt8(ascii: " ") })
        guard (15...34).contains(compact.count) else { return false }

        var remainder = 0
        for byte in compact[4...] + compact[..<4] {
            let number = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? String(Int(byte) - 55) : String(UnicodeScalar(byte))
            for digit in number.utf8 {
                remainder = (remainder * 10 + Int(digit) - 48) % 97
            }
        }
        return remainder == 1
    }

    private static func isSensitiveKey(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        let normalized = key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return sensitiveKeys.contains { normalized.contains($0) }
    }
}
