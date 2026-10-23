@testable import ForgeOpsTracker
import XCTest

final class PiiScrubberTests: XCTestCase {
    // Fixtures/pii_scrubbing_vectors.json is kept byte-identical to sdks/pii_scrubbing_vectors.json,
    // which the server's own implementation generates.
    private func vectors() throws -> [String: [[String: Any]]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pii_scrubbing_vectors", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
    }

    func testScrubsEverySharedCardNumberAndIbanVectorExactlyAsTheServerDoes() throws {
        let entries = try XCTUnwrap(vectors()["strings"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let input = try XCTUnwrap(entry["input"] as? String)
            let scrubbed = try XCTUnwrap(entry["scrubbed"] as? String)
            XCTAssertEqual(PiiScrubber.scrubString(input), scrubbed, "scrubbing \(input)")
        }
    }

    func testRedactsEverySharedBankDetailKeyVectorExactlyAsTheServerDoes() throws {
        let entries = try XCTUnwrap(vectors()["keys"])
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let key = try XCTUnwrap(entry["key"] as? String)
            let redacted = try XCTUnwrap(entry["redacted"] as? Bool)
            let result = try XCTUnwrap(PiiScrubber.scrub([key: "x"], key: nil) as? [String: Any])
            XCTAssertEqual(result[key] as? String, redacted ? PiiScrubber.redacted : "x", "key \(key)")
        }
    }

    func testScrubStringEmail() {
        XCTAssertEqual(PiiScrubber.scrubString("contact user@example.com for help"), "contact [EMAIL FILTERED] for help")
    }

    func testScrubStringCreditCard() {
        XCTAssertNotEqual(PiiScrubber.scrubString("charged card 4242-4242-4242-4242 successfully"), "charged card 4242-4242-4242-4242 successfully")
    }

    func testScrubStringLeavesOrdinaryNumericIdAlone() {
        let text = "order id 1234567890123456"
        XCTAssertEqual(PiiScrubber.scrubString(text), text)
    }

    func testScrubStringSSN() {
        XCTAssertEqual(PiiScrubber.scrubString("ssn on file: 123-45-6789"), "ssn on file: [SSN FILTERED]")
    }

    func testScrubStringKnownTokenFormats() {
        let cases = [
            "Authorization: Bearer abc123DEF.456-xyz",
            "aws key AKIAABCDEFGHIJKLMNOP in use",
            "stripe key sk_live_abcdefghijklmnop",
            "github token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQ",
        ]
        for text in cases {
            XCTAssertNotEqual(PiiScrubber.scrubString(text), text, "expected \(text) to be redacted")
        }
    }

    func testScrubRedactsWholeValueUnderSensitiveKey() {
        let result = PiiScrubber.scrub(12345, key: "apiKey") as? String
        XCTAssertEqual(result, PiiScrubber.redacted)
    }

    func testScrubRecursesIntoDictionariesAndArrays() {
        let input: [String: Any] = [
            "password": "hunter2",
            "note": "email me at user@example.com",
            "items": [
                ["token": "abc"],
                "visit user@example.com",
            ],
        ]

        guard let scrubbed = PiiScrubber.scrub(input, key: nil) as? [String: Any] else {
            return XCTFail("expected a dictionary back")
        }

        XCTAssertEqual(scrubbed["password"] as? String, PiiScrubber.redacted)
        XCTAssertEqual(scrubbed["note"] as? String, "email me at [EMAIL FILTERED]")

        guard let items = scrubbed["items"] as? [Any] else { return XCTFail("expected items to be an array") }
        guard let first = items[0] as? [String: Any] else { return XCTFail("expected items[0] to be a dictionary") }
        XCTAssertEqual(first["token"] as? String, PiiScrubber.redacted)
        XCTAssertEqual(items[1] as? String, "visit [EMAIL FILTERED]")
    }

    func testIsSensitiveKeyIgnoresCaseAndPunctuation() {
        for key in ["API_KEY", "Api-Key", "apiKey", "X-Api-Key"] {
            let redactedResult = PiiScrubber.scrub("value", key: key) as? String
            XCTAssertEqual(redactedResult, PiiScrubber.redacted, "expected \(key) to be treated as sensitive")
        }
        XCTAssertEqual(PiiScrubber.scrub("bob", key: "username") as? String, "bob")
    }
}
