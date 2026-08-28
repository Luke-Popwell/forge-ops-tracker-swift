@testable import ForgeOpsTracker
import XCTest

final class ConfigurationTests: XCTestCase {
    func testDefaults() {
        let config = Configuration()
        XCTAssertEqual(config.environment, "production")
        XCTAssertEqual(config.timeout, 5.0)
        XCTAssertTrue(config.scrubPII)
        XCTAssertTrue(config.enabledEnvironments.contains("production"))
        XCTAssertTrue(config.enabledEnvironments.contains("staging"))
        XCTAssertTrue(config.crashReportsDirectory.contains("com.forgeops.tracker/pending-crash-reports"))
    }

    func testApiKeyAndIngestionURL() {
        let config = Configuration()
        config.dsn = "https://abc123@forgeops.example/api/v1/events"

        XCTAssertEqual(config.apiKey, "abc123")
        XCTAssertEqual(config.ingestionURL?.absoluteString, "https://forgeops.example/api/v1/events")
    }

    func testApiKeyPercentDecodes() {
        let config = Configuration()
        config.dsn = "https://ab%2Fc@forgeops.example/api/v1/events"

        XCTAssertEqual(config.apiKey, "ab/c")
    }

    func testEmptyOrMalformedDSNHasNoApiKeyOrIngestionURL() {
        // Neither has a parseable host at all, so both apiKey and ingestionURL are nil.
        for dsn in ["", "not-a-url"] {
            let config = Configuration()
            config.dsn = dsn
            XCTAssertNil(config.apiKey, "dsn = \(dsn)")
            XCTAssertNil(config.ingestionURL, "dsn = \(dsn)")
        }
    }

    func testDSNWithNoUserinfoHasNoApiKeyButStillHasAnIngestionURL() {
        // A valid host is enough for ingestionURL (there's simply nothing to strip); apiKey
        // specifically needs userinfo, which this DSN doesn't have.
        let config = Configuration()
        config.dsn = "https://forgeops.example/no-userinfo"

        XCTAssertNil(config.apiKey)
        XCTAssertEqual(config.ingestionURL?.absoluteString, "https://forgeops.example/no-userinfo")
    }

    func testIsEnabledRequiresDsnApiKeyAndEnabledEnvironment() {
        let config = Configuration()
        config.dsn = "https://key@host/path"

        config.environment = "production"
        XCTAssertTrue(config.isEnabled)

        config.environment = "development"
        XCTAssertFalse(config.isEnabled)

        config.environment = "production"
        config.dsn = nil
        XCTAssertFalse(config.isEnabled)
    }
}
