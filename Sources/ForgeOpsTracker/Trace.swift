import Foundation

/// One trace: a tree of timed spans (a screen load, a sign-in flow, one network round trip and what
/// it triggered) that is sent to ForgeOps only when the whole thing took at least
/// `Configuration.traceCaptureThreshold` (1s), so fast flows cost nothing on the wire. Start one
/// with `ForgeOpsTracker.startTrace(_:)` or `ForgeOpsTracker.trace(_:_:)`, never directly.
///
/// Unlike the server SDKs, where one request owns one thread, a mobile flow hops between the main
/// queue and background queues, so a trace is an explicit object you pass around (or capture in a
/// closure) rather than ambient per-thread state, and it is safe to use from any thread. Nesting is
/// tracked per thread: a span opened by `measureSpan` becomes the parent of any span recorded on the
/// same thread inside its body, and a span recorded from another thread parents under the root.
///
/// Kinds are the closed set the ingestion API accepts (controller, service, database, redis, http,
/// job, other): anything else is sent as `"other"`, since one bad kind would make the server reject
/// the whole trace. A trace holds at most 500 spans including the root.
///
/// Ids are W3C trace context ids (https://www.w3.org/TR/trace-context/): a 32 lowercase hex trace
/// id and 16 lowercase hex span ids, never all zeros. That is what lets `measureRequest` hand the
/// trace to a backend as a `traceparent` header, and what an error captured inside the trace
/// carries as its `trace_id`, so ForgeOps can show the two sides of one request together.
public final class Trace {
    static let maxSpans = 500
    private static let kinds: Set<String> = ["controller", "service", "database", "redis", "http", "job", "other"]

    private let name: String
    let configuration: Configuration
    private let deliver: ([String: Any]) -> Void
    /// This trace's W3C trace id: 32 lowercase hex characters, never all zeros.
    public let traceId = Trace.generateTraceId()
    private let rootSpanId = Trace.generateSpanId()
    private let startedAt = Date()
    private let timer = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var spans: [[String: Any]] = []
    private var finished = false
    private let stackKey: String

    /// Not part of the public API: `ForgeOpsTracker.startTrace(_:)` builds these.
    init(name: String, configuration: Configuration, deliver: @escaping ([String: Any]) -> Void) {
        self.name = name
        self.configuration = configuration
        self.deliver = deliver
        stackKey = "com.forgeops.tracker.open-spans." + traceId
    }

    /// Times `body` as a span (a child of whatever span is open on this thread, or of the root),
    /// recording it even if `body` throws, and returns whatever `body` returned.
    ///
    /// For a `"database"` span, `statement` is the SQL it ran (a local SQLite query, say) and
    /// `dbSystem` which database it was ("sqlite"): sent in the span's data as `db.statement`, with
    /// every string and number literal replaced by "?" first so values never leave the device, and
    /// `db.system`, lowercased. Both are ignored on any other kind.
    ///
    ///     let rows = try trace.measureSpan("Load orders", kind: "database", statement: sql, dbSystem: "sqlite") { try db.query(sql) }
    @discardableResult
    public func measureSpan<T>(_ name: String, kind: String = "service", data: [String: Any]? = nil,
                               statement: String? = nil, dbSystem: String? = nil, _ body: () throws -> T) rethrows -> T {
        let spanId = Trace.generateSpanId()
        let parent = currentParent()
        pushOpen(spanId)
        Trace.pushCurrent(self)
        let spanStartedAt = Date()
        let spanTimer = DispatchTime.now().uptimeNanoseconds
        defer {
            Trace.popCurrent(self)
            popOpen(spanId)
            store(span(id: spanId, parent: parent, name: name, kind: kind, startedAt: spanStartedAt,
                       durationMs: Double(DispatchTime.now().uptimeNanoseconds - spanTimer) / 1_000_000,
                       data: Trace.spanData(kind: kind, data: data, statement: statement, dbSystem: dbSystem)))
        }
        return try body()
    }

    /// Records a span you timed yourself, under whatever is open on this thread (or the root).
    /// `statement` and `dbSystem` work as they do on `measureSpan`, for a `"database"` span only.
    public func recordSpan(_ name: String, kind: String = "service", startedAt: Date, durationMs: Double, data: [String: Any]? = nil,
                           statement: String? = nil, dbSystem: String? = nil) {
        store(span(id: Trace.generateSpanId(), parent: currentParent(), name: name, kind: kind, startedAt: startedAt, durationMs: durationMs,
                   data: Trace.spanData(kind: kind, data: data, statement: statement, dbSystem: dbSystem)))
    }

    /// A span's data, with a `"database"` span's SQL added as `db.statement` (masked, cut at 4000
    /// characters) and its `db.system`. A `db.statement` passed in `data` directly is masked too, so
    /// raw SQL can never go out on a span.
    static func spanData(kind: String, data: [String: Any]?, statement: String?, dbSystem: String?) -> [String: Any]? {
        guard kind == "database" else { return data }
        var result = data ?? [:]
        let raw = statement ?? (result["db.statement"] as? String)
        result["db.statement"] = nil
        if let masked = SqlStatement.mask(raw) {
            result["db.statement"] = masked
        }
        let system = (dbSystem ?? (result["db.system"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        result["db.system"] = nil
        if let system, !system.isEmpty {
            result["db.system"] = system.lowercased()
        }
        return result
    }

    /// Starts an `http` span for one outgoing request and returns it with the request to send:
    /// `span.request` carries a `traceparent` header whose parent id is this span's own id (unless
    /// `Configuration.propagateTraces` is off, the host isn't in `tracePropagationTargets`, or the
    /// request already had one), so a backend that continues the trace nests its root span under
    /// this one. Call `span.finish(response:error:)` when the call completes; the span is named
    /// "<method> <host>" (never the path, which can carry ids) unless you pass `name`. For
    /// completion-handler code; `measureRequest` does all of this around a closure.
    public func startRequestSpan(_ request: URLRequest, name: String? = nil) -> RequestSpan {
        RequestSpan(trace: self, request: request, name: name)
    }

    /// Sends `request` through `body` with the `traceparent` header added (see `startRequestSpan`)
    /// and records the `http` span around it, even if `body` throws (the error propagates
    /// unchanged). The status code is recorded when `body` returns a `URLResponse` or a
    /// `(Data, URLResponse)`/`(URL, URLResponse)` pair. Inside `body` this trace is current on the
    /// calling thread, so `ForgeOpsTracker.capture(error:)` there carries its trace id.
    ///
    ///     let (data, response) = try trace.measureRequest(request) { try client.send($0) }
    @discardableResult
    public func measureRequest<T>(_ request: URLRequest, name: String? = nil, _ body: (URLRequest) throws -> T) rethrows -> T {
        let span = startRequestSpan(request, name: name)
        var response: URLResponse?
        Trace.pushCurrent(self)
        defer {
            Trace.popCurrent(self)
            span.finish(response: response)
        }
        let result = try body(span.request)
        response = RequestSpan.response(in: result)
        return result
    }

    /// The async form, for `URLSession`'s own async API. A suspended task can resume on another
    /// thread, so this one does not make the trace current: pass `trace:` to
    /// `ForgeOpsTracker.capture(error:)` in async code.
    ///
    ///     let (data, response) = try await trace.measureRequest(request) { try await URLSession.shared.data(for: $0) }
    @discardableResult
    public func measureRequest<T>(_ request: URLRequest, name: String? = nil, _ body: (URLRequest) async throws -> T) async rethrows -> T {
        let span = startRequestSpan(request, name: name)
        var response: URLResponse?
        defer { span.finish(response: response) }
        let result = try await body(span.request)
        response = RequestSpan.response(in: result)
        return result
    }

    /// Ends the trace and sends it if the root took long enough. Idempotent: a second call does
    /// nothing, and spans recorded after it are dropped.
    public func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let recorded = spans
        lock.unlock()

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - timer) / 1_000_000
        guard durationMs >= configuration.traceCaptureThreshold * 1000 else { return }

        let root = span(id: rootSpanId, parent: nil, name: name, kind: "controller", startedAt: startedAt, durationMs: durationMs, data: nil)
        deliver(["trace_id": traceId, "spans": [root] + recorded])
    }

    /// Not part of the public API: records a span whose id was chosen before it started (a
    /// `RequestSpan`, whose id already went out in a header).
    func recordSpan(id: String, parent: String, name: String, kind: String, startedAt: Date, durationMs: Double, data: [String: Any]?) {
        store(span(id: id, parent: parent, name: name, kind: kind, startedAt: startedAt, durationMs: durationMs, data: data))
    }

    private func store(_ span: [String: Any]) {
        lock.lock()
        if !finished, spans.count < Trace.maxSpans - 1 { // leave room for the root
            spans.append(span)
        }
        lock.unlock()
    }

    private func span(id: String, parent: String?, name: String, kind: String, startedAt: Date, durationMs: Double, data: [String: Any]?) -> [String: Any] {
        [
            "span_id": id,
            "parent_span_id": parent as Any? ?? NSNull(),
            "name": name,
            "kind": Trace.kinds.contains(kind) ? kind : "other",
            "started_at": Trace.timestamp(startedAt),
            "duration_ms": (durationMs * 100).rounded() / 100,
            "environment": configuration.environment,
            "release": configuration.releaseVersion as Any? ?? NSNull(),
            "data": data ?? [:],
        ]
    }

    // The open-span stack for this trace on the calling thread, kept in the thread's own dictionary
    // keyed by this trace's id so two traces in flight on one thread never see each other's spans.
    func currentParent() -> String {
        (Thread.current.threadDictionary[stackKey] as? [String])?.last ?? rootSpanId
    }

    private func pushOpen(_ id: String) {
        var stack = (Thread.current.threadDictionary[stackKey] as? [String]) ?? []
        stack.append(id)
        Thread.current.threadDictionary[stackKey] = stack
    }

    private func popOpen(_ id: String) {
        guard var stack = Thread.current.threadDictionary[stackKey] as? [String] else { return }
        stack.removeAll { $0 == id }
        Thread.current.threadDictionary[stackKey] = stack.isEmpty ? nil : stack
    }

    // The traces current on the calling thread, innermost last: `ForgeOpsTracker.trace`'s body,
    // `measureSpan`'s and the synchronous `measureRequest`'s. Only ever pushed and popped around a
    // synchronous body on one thread, so the two always balance.
    private static let currentKey = "com.forgeops.tracker.current-traces"

    /// Not part of the public API: the innermost trace whose synchronous body is running on this
    /// thread, which an error captured there without an explicit `trace:` links to.
    static var current: Trace? {
        (Thread.current.threadDictionary[currentKey] as? [Trace])?.last
    }

    static func pushCurrent(_ trace: Trace) {
        var stack = (Thread.current.threadDictionary[currentKey] as? [Trace]) ?? []
        stack.append(trace)
        Thread.current.threadDictionary[currentKey] = stack
    }

    static func popCurrent(_ trace: Trace) {
        guard var stack = Thread.current.threadDictionary[currentKey] as? [Trace],
              let index = stack.lastIndex(where: { $0 === trace }) else { return }
        stack.remove(at: index)
        Thread.current.threadDictionary[currentKey] = stack.isEmpty ? nil : stack
    }

    /// 32 lowercase hex characters, the W3C trace-id format.
    static func generateTraceId() -> String {
        nonZeroHex(16)
    }

    /// 16 lowercase hex characters, the W3C parent-id (span id) format.
    static func generateSpanId() -> String {
        nonZeroHex(8)
    }

    // The spec reserves all zeros as invalid, and a receiver discards a header carrying one, so
    // that one value in 2^64 (or 2^128) is drawn again rather than sent.
    private static func nonZeroHex(_ bytes: Int) -> String {
        while true {
            let hex = randomHex(bytes)
            if hex.contains(where: { $0 != "0" }) { return hex }
        }
    }

    private static func randomHex(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< bytes).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255, using: &generator)) }.joined()
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    private static let formatterLock = NSLock()

    static func timestamp(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(from: date)
    }
}

/// `ForgeOpsTracker.startTrace(_:)` returns `nil` when tracing is off or reporting isn't enabled, so
/// these forward to the body unchanged in that case: callers never need to unwrap.
public extension Optional where Wrapped == Trace {
    @discardableResult
    func measureSpan<T>(_ name: String, kind: String = "service", data: [String: Any]? = nil,
                        statement: String? = nil, dbSystem: String? = nil, _ body: () throws -> T) rethrows -> T {
        if let trace = self {
            return try trace.measureSpan(name, kind: kind, data: data, statement: statement, dbSystem: dbSystem, body)
        }
        return try body()
    }

    func recordSpan(_ name: String, kind: String = "service", startedAt: Date, durationMs: Double, data: [String: Any]? = nil,
                    statement: String? = nil, dbSystem: String? = nil) {
        self?.recordSpan(name, kind: kind, startedAt: startedAt, durationMs: durationMs, data: data, statement: statement, dbSystem: dbSystem)
    }

    func finish() {
        self?.finish()
    }

    /// With no trace, a span that sends `request` unchanged and records nothing.
    func startRequestSpan(_ request: URLRequest, name: String? = nil) -> RequestSpan {
        self?.startRequestSpan(request, name: name) ?? RequestSpan(trace: nil, request: request, name: name)
    }

    @discardableResult
    func measureRequest<T>(_ request: URLRequest, name: String? = nil, _ body: (URLRequest) throws -> T) rethrows -> T {
        if let trace = self {
            return try trace.measureRequest(request, name: name, body)
        }
        return try body(request)
    }

    @discardableResult
    func measureRequest<T>(_ request: URLRequest, name: String? = nil, _ body: (URLRequest) async throws -> T) async rethrows -> T {
        if let trace = self {
            return try await trace.measureRequest(request, name: name, body)
        }
        return try await body(request)
    }
}

/// Delivers finished traces to the spans endpoint, one at a time on a private serial queue, so
/// finishing a slow trace never blocks the caller on the network. Bounded: once `limit` traces are
/// waiting, a new one is dropped rather than queued, since a flow slow enough to be traced must not
/// also grow this app's memory. Nothing is delivered at exit and an iOS app is suspended shortly
/// after it backgrounds, so a flow that ends right before that should call
/// `ForgeOpsTracker.flushSpans()`.
final class SpanQueue {
    static let limit = 100

    private let client: Client
    private let queue = DispatchQueue(label: "com.forgeops.tracker.spans")
    private let lock = NSLock()
    private var pending = 0
    private var discarded = false

    init(client: Client) {
        self.client = client
    }

    /// Returns `false` (dropping the trace) when the queue is full.
    @discardableResult
    func push(_ trace: [String: Any]) -> Bool {
        lock.lock()
        if pending >= SpanQueue.limit {
            lock.unlock()
            return false
        }
        pending += 1
        lock.unlock()

        queue.async { [self] in
            lock.lock()
            let skip = discarded
            lock.unlock()
            if !skip {
                client.deliverSpans(trace)
            }
            lock.lock()
            pending -= 1
            lock.unlock()
        }
        return true
    }

    /// Blocks until every queued trace has been delivered (or has failed).
    func waitUntilDelivered() {
        queue.sync {}
    }

    /// Drops whatever is still waiting without delivering it.
    func discard() {
        lock.lock()
        discarded = true
        lock.unlock()
    }
}
