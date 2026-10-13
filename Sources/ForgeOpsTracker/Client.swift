import Foundation

/// What became of one delivery attempt. `rejected` is a 4xx other than 408 and 429: the server will
/// never take this payload, so whoever holds it lets it go instead of sending it again. `failed` is
/// everything that may work later (no DSN, a network error, a timeout, a 5xx, 408, 429), so the
/// payload is kept and retried, within the bounds each caller sets. `status` is the HTTP status that
/// decided it, or 0 when there was no response at all.
enum DeliveryOutcome: Equatable {
    case delivered
    case rejected(status: Int)
    case failed(status: Int)

    static func from(status: Int) -> DeliveryOutcome {
        if (200 ..< 300).contains(status) { return .delivered }
        if (400 ..< 500).contains(status), status != 408, status != 429 { return .rejected(status: status) }
        return .failed(status: status)
    }

    /// Why a payload was let go, for the one log line that says so.
    var reason: String {
        switch self {
        case .delivered: return "delivered"
        case let .rejected(status): return "rejected by the server (HTTP \(status))"
        case let .failed(status): return status == 0 ? "the server could not be reached" : "the server answered HTTP \(status)"
        }
    }
}

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
        attempt(payload) == .delivered
    }

    /// Same delivery contract as `deliver`, against the DSN's performance_samples endpoint (see
    /// `Configuration.performanceSamplesURL`). `samples` is wrapped as `{"samples": [...]}`, the
    /// shape `Api::V1::PerformanceSamplesController` expects.
    @discardableResult
    public func deliverPerformanceSamples(_ samples: [[String: Any]]) -> Bool {
        attemptPerformanceSamples(samples) == .delivered
    }

    /// Same delivery contract again, against the DSN's custom metrics and infrastructure metrics
    /// endpoints. `entries` is wrapped as `{"metrics": [...]}`, the shape
    /// `Api::V1::CustomMetricsController` and `Api::V1::InfrastructureMetricsController` expect.
    @discardableResult
    public func deliverMetrics(_ entries: [[String: Any]]) -> Bool {
        attemptMetrics(entries) == .delivered
    }

    @discardableResult
    public func deliverInfrastructureMetrics(_ entries: [[String: Any]]) -> Bool {
        attemptInfrastructureMetrics(entries) == .delivered
    }

    /// Same delivery contract again, against the DSN's spans endpoint (see `Configuration.spansURL`).
    /// `trace` is sent as-is: `{"trace_id": ..., "spans": [...]}`, the shape `Api::V1::SpansController`
    /// expects.
    @discardableResult
    public func deliverSpans(_ trace: [String: Any]) -> Bool {
        post(trace, to: configuration.spansURL) == .delivered
    }

    /// Same delivery contract again, against the DSN's changes endpoint (see
    /// `Configuration.changesURL`). A 403 (a plan without change tracking) is just a `false` like
    /// any other rejection.
    @discardableResult
    public func deliverChange(_ change: [String: Any]) -> Bool {
        post(change, to: configuration.changesURL) == .delivered
    }

    /// Not part of the public API: the same requests as the `deliver*` functions above, for the
    /// callers inside this package that hold on to a payload and so need to know whether a failure
    /// is final (see `DeliveryOutcome`), not only that it happened.
    func attempt(_ payload: [String: Any]) -> DeliveryOutcome {
        post(payload, to: configuration.ingestionURL)
    }

    func attemptPerformanceSamples(_ samples: [[String: Any]]) -> DeliveryOutcome {
        post(["samples": samples], to: configuration.performanceSamplesURL)
    }

    func attemptMetrics(_ entries: [[String: Any]]) -> DeliveryOutcome {
        post(["metrics": entries], to: configuration.customMetricsURL)
    }

    func attemptInfrastructureMetrics(_ entries: [[String: Any]]) -> DeliveryOutcome {
        post(["metrics": entries], to: configuration.infrastructureMetricsURL)
    }

    private func post(_ payload: [String: Any], to url: URL?) -> DeliveryOutcome {
        guard let url, let apiKey = configuration.apiKey else {
            return .failed(status: 0)
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed(status: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var outcome = DeliveryOutcome.failed(status: 0)
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse {
                outcome = DeliveryOutcome.from(status: http.statusCode)
            }
            semaphore.signal()
        }
        task.resume()

        // deliver is documented as synchronous; a hard timeout guard here regardless of the
        // request's own timeoutIntervalForRequest, since a caller relying on this being bounded
        // shouldn't also have to trust that every possible URLSession failure mode still calls the
        // completion handler.
        _ = semaphore.wait(timeout: .now() + configuration.timeout + 1.0)
        return outcome
    }
}
