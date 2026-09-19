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
public final class Trace {
    static let maxSpans = 500
    private static let kinds: Set<String> = ["controller", "service", "database", "redis", "http", "job", "other"]

    private let name: String
    private let configuration: Configuration
    private let deliver: ([String: Any]) -> Void
    private let traceId = Trace.randomHex(16)
    private let rootSpanId = Trace.randomHex(8)
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
    @discardableResult
    public func measureSpan<T>(_ name: String, kind: String = "service", data: [String: Any]? = nil, _ body: () throws -> T) rethrows -> T {
        let spanId = Trace.randomHex(8)
        let parent = currentParent()
        pushOpen(spanId)
        let spanStartedAt = Date()
        let spanTimer = DispatchTime.now().uptimeNanoseconds
        defer {
            popOpen(spanId)
            store(span(id: spanId, parent: parent, name: name, kind: kind, startedAt: spanStartedAt,
                       durationMs: Double(DispatchTime.now().uptimeNanoseconds - spanTimer) / 1_000_000, data: data))
        }
        return try body()
    }

    /// Records a span you timed yourself, under whatever is open on this thread (or the root).
    public func recordSpan(_ name: String, kind: String = "service", startedAt: Date, durationMs: Double, data: [String: Any]? = nil) {
        store(span(id: Trace.randomHex(8), parent: currentParent(), name: name, kind: kind, startedAt: startedAt, durationMs: durationMs, data: data))
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
    private func currentParent() -> String {
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
    func measureSpan<T>(_ name: String, kind: String = "service", data: [String: Any]? = nil, _ body: () throws -> T) rethrows -> T {
        if let trace = self {
            return try trace.measureSpan(name, kind: kind, data: data, body)
        }
        return try body()
    }

    func recordSpan(_ name: String, kind: String = "service", startedAt: Date, durationMs: Double, data: [String: Any]? = nil) {
        self?.recordSpan(name, kind: kind, startedAt: startedAt, durationMs: durationMs, data: data)
    }

    func finish() {
        self?.finish()
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
