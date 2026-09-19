import Foundation

/// Collects individual `captureMetric`/`captureInfrastructureMetric` calls in-process and
/// periodically flushes them as one batch, rather than one network call per capture. Unlike
/// `PerformanceFlusher` this keeps a list of individually meaningful entries instead of summing them
/// into buckets: a customer's own signup or payment is exactly the kind of thing they will want a
/// genuinely accurate count/sum of later, so the server stores one row per entry as-is. Ported from
/// `gems/forge_ops_tracker`'s `metric_buffer.rb` and `infrastructure_metric_buffer.rb`, which are the
/// same class twice; here it is one class instantiated twice, told which delivery function and flush
/// interval to use.
///
/// Three deliberate differences from the Ruby buffers:
///
/// - A flush snapshots the first N entries and, on success, removes exactly those N, instead of
///   resetting the whole list, so an entry recorded while the request is in flight (the lock is
///   released around the network call) is kept for the next flush rather than lost.
/// - The buffer is capped at `maxEntries`, and once full further entries are dropped until a flush
///   succeeds: a plan without the feature answers 403 on every flush, and an uncapped buffer would
///   then grow for as long as the process lives. Dropping the newest rather than the oldest keeps the
///   entries a flush is delivering at the front of the array, which is what makes removing exactly
///   them afterward exact.
/// - A NaN or infinite value is dropped at record time: `JSONSerialization` raises an Objective-C
///   exception for one, which Swift cannot catch, so it would crash the host app.
///
/// The same lazily created `DispatchSourceTimer` as `PerformanceFlusher`. Nothing is flushed at exit
/// and an iOS app is suspended shortly after it backgrounds, so call
/// `ForgeOpsTracker.flushMetrics()` from `applicationDidEnterBackground` or before a command-line tool
/// quits.
public final class MetricBuffer {
    public static let maxEntries = 1000

    private let configuration: Configuration
    private let deliver: ([[String: Any]]) -> Bool
    private let interval: () -> TimeInterval
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    private let queue = DispatchQueue(label: "com.forgeops.tracker.metrics")
    private var timer: DispatchSourceTimer?

    /// Not part of the public API: called between the snapshot and the delivery inside `flush`, with no
    /// lock held, so a test can record "concurrently" at exactly the moment the race window is open.
    var beforeDeliveryHook: (() -> Void)?

    /// `deliver` takes a batch and returns whether delivery succeeded; `interval` is read on every arm of the timer.
    public init(configuration: Configuration, deliver: @escaping ([[String: Any]]) -> Bool, interval: @escaping () -> TimeInterval) {
        self.configuration = configuration
        self.deliver = deliver
        self.interval = interval
    }

    /// Adds one entry (everything but `recorded_at`, which is stamped here). Returns whether it was kept.
    @discardableResult
    public func record(_ entry: [String: Any]) -> Bool {
        guard let value = (entry["value"] as? NSNumber)?.doubleValue, value.isFinite else { return false }

        var stamped = entry
        stamped["recorded_at"] = MetricBuffer.timestamp()

        lock.lock()
        if entries.count >= MetricBuffer.maxEntries {
            lock.unlock()
            return false
        }
        entries.append(stamped)
        let needsTimer = timer == nil
        lock.unlock()

        if needsTimer {
            startTimer()
        }
        return true
    }

    /// Delivers everything buffered so far as one batch (synchronously: blocks the calling thread on the
    /// network). A failed delivery keeps every entry, so the next flush's batch just grows.
    public func flush() {
        lock.lock()
        if entries.isEmpty {
            lock.unlock()
            return
        }
        let snapshot = entries
        let hook = beforeDeliveryHook
        lock.unlock()

        hook?()

        guard deliver(snapshot) else { return }

        lock.lock()
        // Exactly the entries just delivered: anything recorded while the request was in flight sits
        // after them and stays for the next flush.
        entries.removeFirst(min(snapshot.count, entries.count))
        lock.unlock()
    }

    /// Cancels the timer and drops every entry without delivering anything.
    public func discard() {
        lock.lock()
        let current = timer
        timer = nil
        entries.removeAll()
        lock.unlock()
        current?.cancel()
    }

    /// Not part of the public API: how many entries are currently buffered.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private static let formatterLock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime] // no fractional seconds, matches every other SDK's payload
        return formatter
    }()

    private static func timestamp() -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(from: Date())
    }

    private func startTimer() {
        lock.lock()
        if timer != nil {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        timer = source
        lock.unlock()

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.flush()
            self.armTimer()
        }
        armTimer()
        source.resume()
    }

    // Re-read on every arm, not captured once: a change to the interval after the first record takes
    // effect from the next flush on.
    private func armTimer() {
        lock.lock()
        let source = timer
        lock.unlock()
        let seconds = max(interval(), 0.001)
        source?.schedule(deadline: .now() + seconds, repeating: .never, leeway: .milliseconds(Int(seconds * 100)))
    }
}
