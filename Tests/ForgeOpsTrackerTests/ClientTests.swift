@testable import ForgeOpsTracker
import XCTest

final class ClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.recorded = []
        StubURLProtocol.statusCode = 200
    }

    private func testConfiguration(dsn: String) -> Configuration {
        let config = Configuration()
        config.dsn = dsn
        config.timeout = 2.0
        return config
    }

    func testDeliverSendsAuthorizedRequestAndReturnsTrueOn2xx() {
        let config = testConfiguration(dsn: "https://secret-key@forgeops.example/api/v1/events")
        let client = Client(configuration: config, protocolClasses: [StubURLProtocol.self])

        let ok = client.deliver(["message": "boom"])

        XCTAssertTrue(ok)
        XCTAssertEqual(StubURLProtocol.recorded.count, 1)
        let request = StubURLProtocol.recorded[0].request
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(StubURLProtocol.recorded[0].bodyString?.contains("boom") ?? false)
    }

    func testDeliverReturnsFalseOnNon2xx() {
        StubURLProtocol.statusCode = 500
        let config = testConfiguration(dsn: "https://key@forgeops.example/events")
        let client = Client(configuration: config, protocolClasses: [StubURLProtocol.self])

        XCTAssertFalse(client.deliver(["message": "boom"]))
    }

    func testDeliverReturnsFalseWithNoDSN() {
        let config = Configuration()
        let client = Client(configuration: config, protocolClasses: [StubURLProtocol.self])

        XCTAssertFalse(client.deliver(["message": "boom"]))
    }

    func testDeliverReturnsFalseWhenUnreachable() {
        // No stub protocol registered: a real (bogus, reserved) address that will never
        // resolve/connect, exercising the real failure path rather than a stub.
        let config = testConfiguration(dsn: "http://key@127.0.0.1:1/events")
        config.timeout = 0.5
        let client = Client(configuration: config)

        XCTAssertFalse(client.deliver(["message": "boom"]))
    }
}
