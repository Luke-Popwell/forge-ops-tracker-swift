import Foundation

/// Builds the W3C Trace Context `traceparent` header (https://www.w3.org/TR/trace-context/):
/// `00-<32 hex trace id>-<16 hex parent id>-<2 hex flags>`. Only ever written here, never read: an
/// app is where a request starts, not a service one arrives at. Mirrors
/// `gems/forge_ops_tracker/lib/forge_ops_tracker/trace_parent.rb`'s `build`.
enum TraceParent {
    static let header = "traceparent"

    // Always "01" (sampled): whether this trace is sent is only decided when it finishes, long
    // after the header has gone out, so "this may be recorded" is the only honest answer. The
    // backend is free to make its own decision either way.
    static let sampledFlags = "01"

    static func build(traceId: String, spanId: String) -> String {
        "00-\(traceId)-\(spanId)-\(sampledFlags)"
    }
}

/// One outgoing HTTP call inside a trace, from `Trace.startRequestSpan(_:name:)`. Send `request`
/// (not the one you passed in: this copy carries the `traceparent` header) and call `finish` when
/// the call completes, from any thread. The span is recorded as kind `http` with this span's own
/// id, which is the parent id in the header, so the backend's root span nests under it.
///
///     let span = trace.startRequestSpan(request)
///     URLSession.shared.dataTask(with: span.request) { data, response, error in
///         span.finish(response: response, error: error)
///         ...
///     }.resume()
///
/// With no trace (`ForgeOpsTracker.startTrace` returned `nil`), `request` is the one you passed in
/// and `finish` records nothing.
public final class RequestSpan {
    /// The request to send: yours, plus the `traceparent` header when one was added.
    public let request: URLRequest
    /// This span's id (16 lowercase hex characters), or `nil` with no trace.
    public let spanId: String?
    /// The `traceparent` value added to `request`, or `nil` when none was (no trace, propagation
    /// off or not targeted at this host, or the request already carried its own). Useful for a
    /// transport that doesn't take a `URLRequest`, such as a WebSocket handshake.
    public let traceparent: String?

    private let trace: Trace?
    private let parentSpanId: String?
    private let name: String
    private let startedAt = Date()
    private let timer = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var finished = false

    init(trace: Trace?, request: URLRequest, name: String?) {
        self.trace = trace
        let host = request.url?.host
        self.name = name ?? "\(request.httpMethod ?? "GET") \(host ?? "unknown host")"
        guard let trace else {
            self.request = request
            spanId = nil
            parentSpanId = nil
            traceparent = nil
            return
        }

        let spanId = Trace.generateSpanId()
        self.spanId = spanId
        parentSpanId = trace.currentParent()
        var request = request
        // Leaves a traceparent the caller already set alone: whoever set it explicitly knows better
        // than this SDK which trace the call belongs to.
        if trace.configuration.shouldPropagateTrace(to: host), request.value(forHTTPHeaderField: TraceParent.header) == nil {
            let value = TraceParent.build(traceId: trace.traceId, spanId: spanId)
            request.setValue(value, forHTTPHeaderField: TraceParent.header)
            traceparent = value
        } else {
            traceparent = nil
        }
        self.request = request
    }

    /// Records the span, with the response's status code when there is one. Idempotent: only the
    /// first call records anything. `error` is accepted so a completion handler can pass all it
    /// got; a failed call is recorded without a status, the same as the Ruby SDK's outbound spans.
    public func finish(response: URLResponse? = nil, error: Error? = nil) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        guard let trace, let spanId, let parentSpanId else { return }
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - timer) / 1_000_000
        var data: [String: Any] = [:]
        if let status = (response as? HTTPURLResponse)?.statusCode {
            data["status"] = status
        }
        trace.recordSpan(id: spanId, parent: parentSpanId, name: name, kind: "http", startedAt: startedAt, durationMs: durationMs, data: data)
    }

    /// Not part of the public API: the response inside whatever a `measureRequest` body returned,
    /// for the shapes `URLSession` itself returns.
    static func response(in value: Any) -> URLResponse? {
        if let response = value as? URLResponse { return response }
        if let pair = value as? (Data, URLResponse) { return pair.1 }
        if let pair = value as? (URL, URLResponse) { return pair.1 }
        return nil
    }
}
