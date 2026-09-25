import Foundation

/// Public entry point. Typical usage, as early as possible in app startup
/// (`application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App`'s `init`):
///
///     ForgeOpsTracker.configure { config in
///         config.dsn = "https://<api_key>@getforgeops.net/api/v1/events"
///         config.environment = "production"
///     }
///     ForgeOpsTracker.installHandlers()
///
/// See README.md for what `installHandlers` actually covers (an uncaught `NSException`, and the
/// common fatal signals: the same two this repo's own Objective-C client covers) and what it
/// deliberately doesn't (this is a crash reporter, not a web framework's request-exception hook,
/// there's no equivalent to the Django/Express/Servlet-style integrations elsewhere in this repo,
/// since that's not how iOS/macOS apps are shaped), why a crash report always uploads on the
/// *next* launch rather than live during the crash itself, and: new versus the Objective-C
/// client: why nothing here is automatic for a plain Swift `Error`: report those explicitly via
/// `capture(error:context:)`.
public enum ForgeOpsTracker {
    private static var sharedConfiguration: Configuration?
    private static var sharedReporter: Reporter?
    private static var previousUncaughtExceptionHandler: NSUncaughtExceptionHandler?
    private static var handlersInstalled = false
    private static var sharedBreadcrumbs: BreadcrumbBuffer?
    private static let breadcrumbLock = NSLock()
    private static var sharedPerformanceFlusher: PerformanceFlusher?
    private static let performanceLock = NSLock()
    private static var sharedSpanQueue: SpanQueue?
    private static var sharedMetricBuffers: (custom: MetricBuffer, infrastructure: MetricBuffer)?
    private static let metricLock = NSLock()
    private static let spanLock = NSLock()
    private static var sharedChangeClient: Client?
    private static let changeLock = NSLock()
    /// Serial, so changes are sent in the order they were recorded, and off the caller's thread,
    /// since `Client.deliver*` blocks on the network.
    private static let changeQueue = DispatchQueue(label: "com.forgeops.tracker.changes", qos: .utility)

    /// The affected user set via `setUser`, if any. A mobile app install is effectively
    /// single-user (unlike a server handling many concurrent requests at once, the reason
    /// `gems/forge_ops_tracker` needs `Thread.current` instead), so this is a plain static
    /// property, not a thread-local. Internal, not private: `Reporter`'s own `uploadPendingReports`
    /// reads it too, to fill in a raw signal-crash report's user at upload time (see that
    /// function's own comment for why a signal handler itself can never safely read this).
    static var currentUser: [String: Any]?

    public static var configuration: Configuration {
        if sharedConfiguration == nil {
            sharedConfiguration = Configuration()
        }
        return sharedConfiguration!
    }

    /// Lazily created under a lock, unlike `sharedReporter`/`sharedConfiguration` above: breadcrumbs
    /// are added from whatever thread happens to be running, so two first calls racing to create
    /// the shared buffer must not each end up with their own.
    private static var breadcrumbBuffer: BreadcrumbBuffer {
        breadcrumbLock.lock()
        defer { breadcrumbLock.unlock() }
        if sharedBreadcrumbs == nil {
            sharedBreadcrumbs = BreadcrumbBuffer(configuration: configuration)
        }
        return sharedBreadcrumbs!
    }

    private static var performanceFlusher: PerformanceFlusher {
        performanceLock.lock()
        defer { performanceLock.unlock() }
        if sharedPerformanceFlusher == nil {
            sharedPerformanceFlusher = PerformanceFlusher(configuration: configuration, client: Client(configuration: configuration))
        }
        return sharedPerformanceFlusher!
    }

    /// The two metric buffers, created together on first use: independent of each other (a program may
    /// only ever call one), but cheap enough that creating both is simpler than tracking which.
    private static var metricBuffers: (custom: MetricBuffer, infrastructure: MetricBuffer) {
        metricLock.lock()
        defer { metricLock.unlock() }
        if sharedMetricBuffers == nil {
            let config = configuration
            let client = Client(configuration: config)
            sharedMetricBuffers = (
                MetricBuffer(configuration: config, deliver: { client.deliverMetrics($0) }, interval: { config.metricFlushInterval }),
                MetricBuffer(configuration: config, deliver: { client.deliverInfrastructureMetrics($0) }, interval: { config.infrastructureMetricFlushInterval })
            )
        }
        return sharedMetricBuffers!
    }

    private static var spanQueue: SpanQueue {
        spanLock.lock()
        defer { spanLock.unlock() }
        if sharedSpanQueue == nil {
            sharedSpanQueue = SpanQueue(client: Client(configuration: configuration))
        }
        return sharedSpanQueue!
    }

    private static var reporter: Reporter {
        if sharedReporter == nil {
            sharedReporter = Reporter(configuration: configuration)
        }
        return sharedReporter!
    }

    @discardableResult
    public static func configure(_ block: (Configuration) -> Void) -> Configuration {
        let config = configuration
        block(config)
        return config
    }

    /// Installs the uncaught-exception handler and the fatal-signal handlers, then uploads any
    /// crash reports left over from a previous launch on a background queue. Call once, after
    /// `configure`.
    public static func installHandlers() {
        guard !handlersInstalled else { return }
        handlersInstalled = true

        // Before the signal handlers, and before anything else can add a breadcrumb that would
        // replace the previous run's persisted trail: see BreadcrumbBuffer.
        _startBreadcrumbPersistence()

        previousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            // The handler runs on the raising thread, so a trace whose synchronous body raised is
            // still current here.
            ForgeOpsTracker.reporter.report(exception: exception, context: nil, user: ForgeOpsTracker.currentUser, breadcrumbs: ForgeOpsTracker.currentBreadcrumbs, traceId: Trace.current?.traceId)
            // Chain to whatever handler (if any) was already installed: another crash reporter,
            // a debugger, or the host app's own: rather than silently replacing it, the same
            // "rethrow, don't swallow" invariant every other framework integration in this repo
            // holds to.
            ForgeOpsTracker.previousUncaughtExceptionHandler?(exception)
        }

        SignalHandler.install(directory: configuration.crashReportsDirectory)

        // Deliberately not the main thread: see Client's own comment on `deliver` being
        // synchronous; a background queue is what keeps that from ever blocking app launch.
        DispatchQueue.global(qos: .utility).async {
            reporter.uploadPendingReports()
        }
    }

    /// Report an exception you've already caught, e.g. from your own `@try`/`@catch` across an
    /// Objective-C boundary. `user` defaults to whatever `setUser` last set, if anything; pass
    /// one explicitly to override that for this one report. `trace` links the report to that trace
    /// (see `capture(error:context:user:trace:)`).
    public static func captureException(_ exception: NSException, context: [String: Any]? = nil, user: [String: Any]? = nil, trace: Trace? = nil) {
        reporter.report(exception: exception, context: context, user: user ?? currentUser, breadcrumbs: currentBreadcrumbs, traceId: (trace ?? Trace.current)?.traceId)
        uploadSoon()
    }

    /// Report a plain Swift `Error` you've already caught: the common case for pure Swift code,
    /// since Swift has nothing equivalent to `NSException`/`NSSetUncaughtExceptionHandler` for its
    /// own `throws`/`catch` mechanism: an error a Swift function throws must always be handled or
    /// explicitly propagated by its caller, so there's no "uncaught Swift error" runtime event to
    /// hook the way there is for `NSException`. `user` defaults to whatever `setUser` last set.
    ///
    /// `trace` links the error to that trace: the event carries its `trace_id`, so ForgeOps shows it
    /// next to a backend error from the same request (see `Trace.measureRequest`). Without one, the
    /// trace whose synchronous body is running on this thread (`trace(_:_:)`, `measureSpan`,
    /// `measureRequest`) is used, if any; async code should pass it explicitly. No trace, no
    /// `trace_id`: the event is exactly what it was before.
    public static func capture(error: Error, context: [String: Any]? = nil, user: [String: Any]? = nil, trace: Trace? = nil) {
        reporter.report(error: error, context: context, user: user ?? currentUser, breadcrumbs: currentBreadcrumbs, traceId: (trace ?? Trace.current)?.traceId)
        uploadSoon()
    }

    /// Manually attaches an affected user to whatever gets reported from here on (an explicit
    /// `capture`/`captureException` call, an uncaught exception, a fatal signal): there's no way
    /// to automatically detect "the current user" on iOS/macOS, so call this yourself, e.g. right
    /// after sign-in. `id`/`email`/`username` are all independently optional; call with `nil` (or
    /// an empty dictionary) to clear whatever was set, e.g. on sign-out.
    public static func setUser(_ user: [String: Any]?) {
        currentUser = (user?.isEmpty ?? true) ? nil : user
    }

    /// Records one breadcrumb: an entry in a small, bounded trail of recent events attached to
    /// whatever gets reported next (a `capture`/`captureException` call, an uncaught exception, or
    /// a fatal signal), so an issue's detail page can show what led up to it. Only the most recent
    /// `Configuration.maxBreadcrumbs` (30) are kept, oldest dropped first; a no-op when
    /// `Configuration.trackBreadcrumbs` is `false`. Safe to call from any thread.
    ///
    /// Nothing records one automatically: there's no request/controller lifecycle in a crash
    /// reporter to time one from, so every breadcrumb is one you add by hand, wherever it's
    /// meaningful (a screen appearing, a network call starting). Once `installHandlers()` has run,
    /// the trail is also written to disk as it changes, so a fatal signal's report (which can only
    /// be uploaded on the next launch, by a different process) still carries the trail that led up
    /// to it. See `BreadcrumbBuffer`.
    ///
    ///     ForgeOpsTracker.addBreadcrumb("charging card", category: "payment", data: ["orderId": order.id])
    public static func addBreadcrumb(_ message: String, category: String = "custom", level: String = "info", data: [String: Any] = [:]) {
        breadcrumbBuffer.add(message: message, category: category, level: level, data: data)
    }

    /// Empties the breadcrumb trail. A mobile app is effectively single-flow (one shared trail,
    /// like `setUser`'s one shared user), so this is only needed to start a new logical unit of
    /// work (say, a new sign-in session) with a fresh trail.
    public static func clearBreadcrumbs() {
        breadcrumbBuffer.clear()
    }

    /// Not part of the public API: the trail as it stands right now.
    static var currentBreadcrumbs: [[String: Any]] {
        breadcrumbBuffer.all()
    }

    /// Not part of the public API: the previous run's persisted trail, if it plausibly belongs to
    /// a crash that happened at `crashDate`, read by `Reporter` when completing a raw signal
    /// report at upload time. See `BreadcrumbBuffer`.
    static func previousRunBreadcrumbs(forCrashOccurringAt crashDate: Date) -> [[String: Any]]? {
        breadcrumbBuffer.previousRunBreadcrumbs(forCrashOccurringAt: crashDate)
    }

    /// Not part of the public API: reads the previous run's persisted trail and begins persisting
    /// this run's. `installHandlers()` calls this itself; separate so it can be exercised without
    /// installing real process-wide signal handlers.
    static func _startBreadcrumbPersistence() {
        breadcrumbBuffer.startPersisting()
    }

    /// Not part of the public API: blocks until breadcrumb persistence writes have finished.
    static func _waitForBreadcrumbWrites() {
        breadcrumbBuffer._waitForPendingWrites()
    }

    /// Records one timed call's duration, in milliseconds, under `transactionName`: tallied
    /// in-process (count, total, max) and flushed every `Configuration.performanceFlushInterval`
    /// (60s) as one small aggregate report per transaction, for the Performance page's
    /// per-transaction table, not one network call per call. A no-op when
    /// `Configuration.trackPerformance` is `false` or reporting isn't enabled for this environment.
    /// Safe to call from any thread.
    ///
    /// This client has no web framework integration, so nothing is timed automatically: wrap
    /// whatever you want on the Performance page yourself, with `measureTransaction`, or call this
    /// directly with a duration you measured. Keep `transactionName` low-cardinality
    /// (`"GET /users/:id"`, not `"GET /users/42"`): every distinct name is its own row.
    public static func recordPerformance(_ transactionName: String, durationMs: Double) {
        performanceFlusher.record(transactionName: transactionName, durationMs: durationMs)
    }

    /// Runs `body`, records how long it took under `transactionName` (see `recordPerformance`), and
    /// returns whatever `body` returned. Recorded even if `body` throws (the error propagates
    /// unchanged): a handler that fails is exactly one worth seeing on the Performance page.
    ///
    ///     let user = try ForgeOpsTracker.measureTransaction("load-user") { try loadUser(id) }
    public static func measureTransaction<T>(_ transactionName: String, _ body: () throws -> T) rethrows -> T {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            recordPerformance(transactionName, durationMs: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        }
        return try body()
    }

    /// Delivers whatever has been tallied so far right now (synchronously: blocks the calling thread
    /// on the network), instead of waiting for the next timer tick. A `DispatchSourceTimer` flushes
    /// on its own every `performanceFlushInterval`, but an iOS app is suspended shortly after it goes
    /// to the background and nothing is flushed at exit, so call this from
    /// `applicationDidEnterBackground`/`sceneDidEnterBackground` (on a background queue if you'd
    /// rather not block the main thread) or before a command-line tool quits.
    public static func flushPerformance() {
        performanceFlusher.flush()
    }

    /// Custom metrics and infrastructure monitoring: two explicit calls (nothing is automatic, so there
    /// is no `trackMetrics` flag). `captureMetric` records a named business event (a signup, a payment,
    /// anything you want to name): `value` defaults to 1 for a bare counter; pass one for a real
    /// magnitude, and it may be negative (a refund). `captureInfrastructureMetric` records one reading
    /// (cpu, memory, disk, anything else a program of yours reads) from one of your own hosts;
    /// `hostname` defaults to `Configuration.serverName`. Both are buffered and flushed as one batch
    /// every `Configuration.metricFlushInterval`/`infrastructureMetricFlushInterval` (60s) on a private
    /// serial queue, off the calling thread. Every entry is stored as captured (a signup is a row, not a
    /// running total), so a count or sum computed later is exact. Both are a no-op when reporting isn't
    /// enabled for this environment, and a NaN or infinite value is dropped. A buffer holds at most
    /// `MetricBuffer.maxEntries` entries and drops further ones until a flush succeeds; a failed delivery
    /// keeps every entry, and one captured while a delivery is in flight is kept too.
    ///
    ///     ForgeOpsTracker.captureMetric("signup")
    ///     ForgeOpsTracker.captureMetric("payment", value: 49)
    ///     ForgeOpsTracker.captureInfrastructureMetric("cpu", value: 0.42)
    public static func captureMetric(_ name: String, value: Double = 1) {
        guard configuration.isEnabled else { return }
        metricBuffers.custom.record([
            "metric_name": name,
            "value": value,
            "environment": configuration.environment,
            "release": configuration.releaseVersion as Any? ?? NSNull(),
        ])
    }

    public static func captureInfrastructureMetric(_ name: String, value: Double, hostname: String? = nil) {
        guard configuration.isEnabled else { return }
        guard let resolved = hostname ?? configuration.serverName, !resolved.isEmpty else {
            // The endpoint requires a hostname and skips a row without one: say so here instead of sending it.
            NSLog("[forge-ops-tracker] dropped an infrastructure metric with no hostname: pass one or set serverName")
            return
        }
        metricBuffers.infrastructure.record([
            "metric_name": name,
            "value": value,
            "hostname": resolved,
        ])
    }

    /// Delivers every buffered metric and infrastructure reading right now (synchronously: blocks the
    /// calling thread on the network). An iOS app is suspended shortly after it goes to the background
    /// and nothing is flushed at exit, so call this from `applicationDidEnterBackground` (on a
    /// background queue if you'd rather not block the main thread) or before a command-line tool quits.
    public static func flushMetrics() {
        metricLock.lock()
        let buffers = sharedMetricBuffers
        metricLock.unlock()
        buffers?.custom.flush()
        buffers?.infrastructure.flush()
    }

    /// Records one change to what the app is running: a feature flag flipped, a remote config value
    /// updated, anything that could explain a shift in crashes or errors. ForgeOps shows it on the
    /// timeline next to the errors around it. `kind` is one of feature_flag, config, migration,
    /// dependency, infrastructure, other (anything else is sent as `"other"`); `title` is required and
    /// cut to 200 characters. `details` is a small JSON object; `environment` defaults to
    /// `Configuration.environment`; `url` must be http(s); `id` is an idempotency key.
    ///
    /// Returns immediately: the change is sent on a private serial queue, off the calling thread, and
    /// nothing here ever throws or crashes the app, whether the request fails or the plan doesn't
    /// include change tracking. A no-op when reporting isn't enabled for this environment.
    ///
    ///     flags.onChange { key, oldValue, newValue in
    ///         ForgeOpsTracker.recordChange("feature_flag", title: "\(key) turned \(newValue ? "on" : "off")",
    ///                                      details: ["key": key, "from": oldValue, "to": newValue])
    ///     }
    public static func recordChange(
        _ kind: String,
        title: String,
        details: [String: Any]? = nil,
        environment: String? = nil,
        service: String? = nil,
        actor: String? = nil,
        url: String? = nil,
        id: String? = nil,
        occurredAt: Date? = nil
    ) {
        let config = configuration
        guard config.isEnabled else { return }
        guard let payload = Change.payload(
            kind: kind, title: title, details: details, environment: environment, service: service,
            actor: actor, url: url, id: id, occurredAt: occurredAt, configuration: config
        ) else {
            NSLog("[forge-ops-tracker] dropped a change with no title")
            return
        }

        changeLock.lock()
        if sharedChangeClient == nil {
            sharedChangeClient = Client(configuration: config)
        }
        let client = sharedChangeClient!
        changeLock.unlock()

        changeQueue.async {
            client.deliverChange(payload)
        }
    }

    /// Not part of the public API: blocks until every change recorded so far has been sent.
    static func _waitForChanges() {
        changeQueue.sync {}
    }

    /// Distributed tracing: one flow's own call tree (a screen load, a sign-in, a network round trip
    /// and what it triggered), sent to ForgeOps only when the whole thing took at least
    /// `Configuration.traceCaptureThreshold` (1s), so fast flows cost nothing on the wire. An
    /// outgoing request made with `trace.measureRequest` carries a W3C `traceparent` header, so a
    /// backend that also reports to ForgeOps continues the trace, and an error captured inside the
    /// trace carries its `trace_id`.
    ///
    ///     ForgeOpsTracker.trace("load home screen") { trace in
    ///         let feed = trace.measureSpan("fetch feed", kind: "http") { fetchFeed() }
    ///         trace.measureSpan("decode", kind: "service", data: ["items": feed.count]) { decode(feed) }
    ///     }
    ///
    /// Or hold the trace yourself across queues and finish it when the flow ends:
    ///
    ///     let trace = ForgeOpsTracker.startTrace("checkout")
    ///     ...                       // any thread: trace.measureSpan(...) { ... }
    ///     trace.finish()
    ///
    /// Returns `nil` when `Configuration.trackTracing` is `false` or reporting isn't enabled for this
    /// environment; `measureSpan`, `recordSpan` and `finish` are also available on the optional, so
    /// callers never unwrap. `kind` is one of controller, service, database, redis, http, job, other
    /// (anything else is sent as `"other"`). This client has no web framework integration, so nothing
    /// starts a trace or records a span automatically. Delivery runs on a private serial queue,
    /// bounded, off the calling thread.
    public static func startTrace(_ name: String) -> Trace? {
        guard configuration.trackTracing, configuration.isEnabled else { return nil }
        let queue = spanQueue
        return Trace(name: name, configuration: configuration) { payload in
            queue.push(payload)
        }
    }

    /// Runs `body` with a new trace and finishes it afterward, even if `body` throws (the error
    /// propagates unchanged). `body` receives `nil` when tracing is off. While `body` runs, the
    /// trace is current on this thread, so `capture(error:)` there links to it.
    public static func trace<T>(_ name: String, _ body: (Trace?) throws -> T) rethrows -> T {
        let trace = startTrace(name)
        if let trace { Trace.pushCurrent(trace) }
        defer {
            if let trace { Trace.popCurrent(trace) }
            trace.finish()
        }
        return try body(trace)
    }

    /// Delivers every finished trace that is still queued right now (synchronously: blocks the
    /// calling thread on the network). An iOS app is suspended shortly after it goes to the
    /// background and nothing is flushed at exit, so call this from `applicationDidEnterBackground`
    /// (on a background queue if you'd rather not block the main thread) or before a command-line
    /// tool quits.
    public static func flushSpans() {
        spanQueue.waitUntilDelivered()
    }

    private static func uploadSoon() {
        // Unlike an uncaught exception/fatal signal, this one didn't crash the process: upload
        // now rather than waiting for a next launch that (having not crashed) has no particular
        // reason to come soon. Still off the calling thread, for the same reason as
        // installHandlers above.
        DispatchQueue.global(qos: .utility).async {
            reporter.uploadPendingReports()
        }
    }

    /// Not part of the public API: resets module state between test cases.
    static func _resetForTesting() {
        sharedConfiguration = nil
        sharedReporter = nil
        handlersInstalled = false
        currentUser = nil
        breadcrumbLock.lock()
        sharedBreadcrumbs = nil
        breadcrumbLock.unlock()
        performanceLock.lock()
        sharedPerformanceFlusher?.discard()
        sharedPerformanceFlusher = nil
        performanceLock.unlock()
        metricLock.lock()
        sharedMetricBuffers?.custom.discard()
        sharedMetricBuffers?.infrastructure.discard()
        sharedMetricBuffers = nil
        metricLock.unlock()
        spanLock.lock()
        sharedSpanQueue?.discard()
        sharedSpanQueue = nil
        spanLock.unlock()
        changeQueue.sync {}
        changeLock.lock()
        sharedChangeClient = nil
        changeLock.unlock()
        // Deliberately not touching the real NSUncaughtExceptionHandler/signal dispositions here:
        // resetting those between test runs would risk leaving the *test process itself*
        // without a safety net if a later, unrelated test genuinely crashes. Same reasoning as
        // this repo's own Objective-C client's own _resetForTesting.
    }
}
