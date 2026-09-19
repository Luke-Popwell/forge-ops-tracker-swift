import Foundation

/// Times work in-process, bucketed by transaction name (see `ForgeOpsTracker.recordPerformance`
/// and `measureTransaction`), and periodically flushes each distinct bucket as one small aggregate
/// report, rather than one network call per timed call. Ported from this repo's own Objective-C
/// client (`sdks/objc/Sources/ForgeOpsTracker/FOTPerformanceFlusher.h`), itself ported from
/// `gems/forge_ops_tracker`'s and `sdks/go`'s, including the one thing those learned the hard way:
/// see `flush`'s own comment on why it subtracts what it delivered instead of clearing the buckets.
///
/// The periodic flush is a `DispatchSourceTimer` on a private serial queue, started on the first
/// recorded duration. A dispatch source never keeps a process alive, so unlike a run-loop `Timer`
/// it can't hold a command-line tool open. There is no next launch to wait for here (unlike this
/// SDK's crash path), so an iOS/macOS app that is about to be suspended or quit should call
/// `ForgeOpsTracker.flushPerformance()` itself (see README.md). Nothing is flushed at exit: an iOS
/// app has no normal exit to hook.
public final class PerformanceFlusher {
    private struct Bucket {
        var count = 0
        var durationSumMs = 0.0
        var maxDurationMs = 0.0
    }

    private let configuration: Configuration
    private let client: Client
    private let lock = NSLock()
    private var buckets: [String: Bucket] = [:]
    private var periodStartedAt = Date()
    private let queue = DispatchQueue(label: "com.forgeops.tracker.performance")
    private var timer: DispatchSourceTimer?

    /// Not part of the public API: called between the snapshot and the delivery inside `flush`, with
    /// no lock held, so a test can record "concurrently" at exactly the moment the race window is
    /// open without needing a second thread.
    var beforeDeliveryHook: (() -> Void)?

    public init(configuration: Configuration, client: Client) {
        self.configuration = configuration
        self.client = client
    }

    /// Does nothing (and starts no timer) when `trackPerformance` is false or reporting isn't
    /// enabled for this environment.
    public func record(transactionName: String, durationMs: Double) {
        guard configuration.trackPerformance, configuration.isEnabled else { return }

        lock.lock()
        var bucket = buckets[transactionName] ?? Bucket()
        bucket.count += 1
        bucket.durationSumMs += durationMs
        bucket.maxDurationMs = max(bucket.maxDurationMs, durationMs)
        buckets[transactionName] = bucket
        let needsTimer = timer == nil
        lock.unlock()

        if needsTimer { startTimer() }
    }

    /// Snapshots the buffered buckets and delivers them as one batch (synchronously: blocks the
    /// calling thread on the network). A failed delivery keeps every bucket where it is, so the next
    /// flush's batch just grows instead of losing what was already tallied: there's no other copy of
    /// this data anywhere.
    ///
    /// Only exactly what this snapshot delivered is removed afterward, subtracted from whatever is
    /// in each bucket by then, never the whole set cleared outright. `record` can run on another
    /// thread while delivery is in flight (the lock is deliberately released around the network
    /// call), so a record for a transaction already in the snapshot, or a brand-new one, can land in
    /// the exact window between the snapshot and delivery succeeding. Clearing afterward, as if
    /// delivery had covered everything now in the set, would silently discard that data forever. This
    /// is a real bug `sdks/go` had and fixed, and that `gems/forge_ops_tracker`'s reference
    /// implementation still has; see this package's own test for a deterministic reproduction.
    public func flush() {
        lock.lock()
        if buckets.isEmpty {
            lock.unlock()
            return
        }
        let snapshot = buckets
        let periodStart = periodStartedAt
        let periodEnd = Date()
        let hook = beforeDeliveryHook
        lock.unlock()

        hook?()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime] // no fractional seconds, matches every other SDK's payload
        let samples: [[String: Any]] = snapshot.map { name, bucket in
            [
                "transaction_name": name,
                "environment": configuration.environment,
                "release": configuration.releaseVersion as Any? ?? NSNull(),
                "period_started_at": formatter.string(from: periodStart),
                "period_ended_at": formatter.string(from: periodEnd),
                "request_count": bucket.count,
                "duration_sum_ms": bucket.durationSumMs,
                "max_duration_ms": bucket.maxDurationMs,
            ]
        }

        guard client.deliverPerformanceSamples(samples) else { return }

        lock.lock()
        for (name, sent) in snapshot {
            guard var current = buckets[name] else { continue }
            current.count = max(0, current.count - sent.count)
            current.durationSumMs = max(0, current.durationSumMs - sent.durationSumMs)
            // maxDurationMs is deliberately left as whatever is currently on the bucket, sent or
            // not: unlike count/durationSumMs, a max can't be correctly "subtracted" back out (the
            // true max of what's left is anything at or below it, not knowable from the two numbers
            // alone), and leaving it never overstates the next period's own max, only potentially
            // understates how far back it was actually set.
            if current.count == 0 {
                buckets.removeValue(forKey: name)
            } else {
                buckets[name] = current
            }
        }
        periodStartedAt = periodEnd
        lock.unlock()
    }

    /// Cancels the timer and drops every bucket without delivering anything.
    public func discard() {
        lock.lock()
        let current = timer
        timer = nil
        buckets.removeAll()
        lock.unlock()
        current?.cancel()
    }

    /// Not part of the public API: `(count, durationSumMs, maxDurationMs)` for one transaction.
    func tally(for transactionName: String) -> (count: Int, durationSumMs: Double, maxDurationMs: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = buckets[transactionName] else { return nil }
        return (bucket.count, bucket.durationSumMs, bucket.maxDurationMs)
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

    // Re-read on every arm, not captured once: a change to `performanceFlushInterval` after the
    // first record takes effect from the next flush on.
    private func armTimer() {
        lock.lock()
        let source = timer
        lock.unlock()
        let interval = max(configuration.performanceFlushInterval, 0.001)
        source?.schedule(deadline: .now() + interval, repeating: .never, leeway: .milliseconds(Int(interval * 100)))
    }
}
