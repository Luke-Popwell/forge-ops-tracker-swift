import Foundation

/// Delivers one payload over HTTP. Every failure mode: DNS, connection, timeout, a non-2xx
/// response: is caught here and turned into a `false` return rather than a thrown error, since a
/// broken or unreachable tracker must never be able to break the host app. Uses `URLSession`, not
/// a third-party dependency: same reasoning as every other SDK in this repo (see e.g.
/// `sdks/node/src/client.js`): this has to work in any host app without adding a dependency of its
/// own for something as simple as one POST request.
///
/// `deliver` is synchronous (blocks the calling thread until the request completes or times out),
/// deliberately: crash report upload here always happens on the *next* app launch (see
/// CrashStore), from a background queue this SDK controls itself, not inline with anything
/// user-facing; there's no live request to avoid blocking the way the other SDKs' async delivery
/// queues exist to protect. Ported from this repo's own Objective-C client
/// (`sdks/objc/Sources/ForgeOpsTracker/FOTClient.h`).
public final class Client {
    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, protocolClasses: [AnyClass]? = nil) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        // protocolClasses is nil in every real use: exposed only so tests can inject a stubbed
        // URLProtocol without this class needing to know it's being tested.
        if let protocolClasses {
            sessionConfig.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: sessionConfig)
    }

    @discardableResult
    public func deliver(_ payload: [String: Any]) -> Bool {
        post(payload, to: configuration.ingestionURL)
    }

    /// Same delivery contract as `deliver`, against the DSN's performance_samples endpoint (see
    /// `Configuration.performanceSamplesURL`). `samples` is wrapped as `{"samples": [...]}`, the
    /// shape `Api::V1::PerformanceSamplesController` expects.
    @discardableResult
    public func deliverPerformanceSamples(_ samples: [[String: Any]]) -> Bool {
        post(["samples": samples], to: configuration.performanceSamplesURL)
    }

    /// Same delivery contract again, against the DSN's custom metrics and infrastructure metrics
    /// endpoints. `entries` is wrapped as `{"metrics": [...]}`, the shape
    /// `Api::V1::CustomMetricsController` and `Api::V1::InfrastructureMetricsController` expect.
    @discardableResult
    public func deliverMetrics(_ entries: [[String: Any]]) -> Bool {
        post(["metrics": entries], to: configuration.customMetricsURL)
    }

    @discardableResult
    public func deliverInfrastructureMetrics(_ entries: [[String: Any]]) -> Bool {
        post(["metrics": entries], to: configuration.infrastructureMetricsURL)
    }

    /// Same delivery contract again, against the DSN's spans endpoint (see `Configuration.spansURL`).
    /// `trace` is sent as-is: `{"trace_id": ..., "spans": [...]}`, the shape `Api::V1::SpansController`
    /// expects.
    @discardableResult
    public func deliverSpans(_ trace: [String: Any]) -> Bool {
        post(trace, to: configuration.spansURL)
    }

    /// Same delivery contract again, against the DSN's changes endpoint (see
    /// `Configuration.changesURL`). A 403 (a plan without change tracking) is just a `false` like
    /// any other rejection.
    @discardableResult
    public func deliverChange(_ change: [String: Any]) -> Bool {
        post(change, to: configuration.changesURL)
    }

    private func post(_ payload: [String: Any], to url: URL?) -> Bool {
        guard let url, let apiKey = configuration.apiKey else {
            return false
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var success = false
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse {
                success = (200 ..< 300).contains(http.statusCode)
            }
            semaphore.signal()
        }
        task.resume()

        // deliver is documented as synchronous; a hard timeout guard here regardless of the
        // request's own timeoutIntervalForRequest, since a caller relying on this being bounded
        // shouldn't also have to trust that every possible URLSession failure mode still calls the
        // completion handler.
        _ = semaphore.wait(timeout: .now() + configuration.timeout + 1.0)
        return success
    }
}
