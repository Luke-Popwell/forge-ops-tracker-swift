import Foundation

/// Holds a single ForgeOps DSN plus everything else the client needs to build and deliver events.
/// Mirrors `gems/forge_ops_tracker/lib/forge_ops_tracker/configuration.rb` (a single DSN string
/// carries both the ingestion URL and the project's api_key:
/// "https://<api_key>@host/api/v1/events") and this repo's own Objective-C client
/// (`sdks/objc/Sources/ForgeOpsTracker/FOTConfiguration.h`): parsed with `URLComponents` rather
/// than a hand-rolled regex, the same reasoning as that client's own header comment: Foundation
/// already has a real, well-tested URL parser that handles the DSN's userinfo segment directly.
public final class Configuration {
    public var dsn: String?
    public var environment: String = "production"
    public var releaseVersion: String?
    public var serverName: String?
    public var enabledEnvironments: Set<String> = ["production", "staging"]
    // Longer than the other SDKs' ~2s default: this fires on the *next* launch after a crash (see
    // CrashStore), not inline with a live request, so there's no user-facing latency to protect.
    public var timeout: TimeInterval = 5.0
    public var scrubPII: Bool = true

    /// Whether `EventBuilder` would read a few lines of source off disk around an in-app frame's
    /// culprit line, the same way the Ruby/Python/Node/etc. clients in this repo do. Defaults to
    /// `true`, mirroring every other SDK, but this flag alone isn't the real protection against
    /// sending source code somewhere it shouldn't go: ForgeOps' own per-project setting is the
    /// durable, server-enforced off switch, since it applies regardless of what this flag happens
    /// to be set to on any given install. Kept here purely for API-shape consistency across every
    /// SDK in this repo: see `EventBuilder`'s own top comment for why this specific client's
    /// capture path is a documented no-op regardless of this value: neither `-callStackSymbols` nor
    /// `Thread.callStackSymbols` ever produces a real file+line pair to read in the first place.
    public var captureSourceContext: Bool = true

    /// When an error carries the SQL behind a failed local database call (GRDB's `DatabaseError`,
    /// SQLite's own `while compiling:` text), send the names of the table and view it touched, so
    /// an issue says where to start looking. Names are identifiers, never values, which is why
    /// this defaults on. `captureSqlStatement` is the separate, opt-in step of also sending the
    /// statement itself, with every string and number replaced by `?`; off by default because even
    /// a masked statement describes your schema, and ForgeOps' own per-project setting is what
    /// durably governs whether the server stores it.
    public var captureSqlObjects: Bool = true

    public var captureSqlStatement: Bool = false

    /// Whether `ForgeOpsTracker.addBreadcrumb` records anything at all. On by default, matching
    /// every other client in this repo.
    public var trackBreadcrumbs: Bool = true

    /// How many of the most recent breadcrumbs are kept, oldest dropped first. 30, matching every
    /// other client's default.
    public var maxBreadcrumbs: Int = 30

    /// Whether `ForgeOpsTracker.recordPerformance`/`measureTransaction` time anything at all. On by
    /// default, the same "on unless you turn it off" posture error reporting itself already has.
    /// This client has no web framework integration, so nothing is timed automatically: this only
    /// gates the manual API.
    public var trackPerformance: Bool = true

    /// How often the in-process tallies are flushed as one small aggregate report, in seconds,
    /// rather than one network call per timed call. Matches `gems/forge_ops_tracker`'s own default.
    public var performanceFlushInterval: TimeInterval = 60

    /// Whether `ForgeOpsTracker.startTrace`/`trace` start a trace at all, and so whether spans are
    /// recorded and slow traces sent. On by default. This client has no web framework integration,
    /// so nothing starts a trace automatically: this only gates the manual API.
    public var trackTracing: Bool = true

    /// A trace is only sent when its root took at least this many seconds. 1, matching every other
    /// client's default.
    public var traceCaptureThreshold: TimeInterval = 1

    /// How often the buffered `captureMetric`/`captureInfrastructureMetric` entries are flushed as one
    /// batch, in seconds (60 by default). There is no `trackMetrics` flag the way `trackPerformance` has
    /// one: these are explicit calls the host app's own code makes, not automatic instrumentation, so
    /// there is nothing to turn off that simply not calling them doesn't already do.
    public var metricFlushInterval: TimeInterval = 60
    public var infrastructureMetricFlushInterval: TimeInterval = 60

    /// Where pending (not-yet-uploaded) crash reports are written: see CrashStore.
    public var crashReportsDirectory: String

    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let base = caches?.path ?? NSTemporaryDirectory()
        crashReportsDirectory = (base as NSString).appendingPathComponent("com.forgeops.tracker/pending-crash-reports")
    }

    private func parsedDSN() -> URLComponents? {
        guard let dsn, !dsn.isEmpty else { return nil }
        guard let components = URLComponents(string: dsn), components.host != nil else { return nil }
        return components
    }

    /// URLComponents already percent-decodes `.user` for us, unlike `.percentEncodedUser`.
    public var apiKey: String? {
        guard let components = parsedDSN(), let user = components.user, !user.isEmpty else { return nil }
        return user
    }

    /// The ingestion URL with credentials stripped out (they travel as the Authorization header
    /// instead).
    public var ingestionURL: URL? {
        guard var components = parsedDSN() else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    /// Same derivation as `ingestionURL`, with the trailing `/events` swapped for
    /// `/performance_samples`: one DSN, two endpoints, matching the Ruby gem's own
    /// `Configuration#performance_samples_uri`.
    public var performanceSamplesURL: URL? {
        guard var components = parsedDSN() else { return nil }
        components.user = nil
        components.password = nil
        if components.path.hasSuffix("/events") {
            components.path = String(components.path.dropLast("/events".count)) + "/performance_samples"
        }
        return components.url
    }

    /// Same derivation again, swapping the trailing `/events` for `/custom_metrics`.
    public var customMetricsURL: URL? { swappingEventsSuffix(for: "/custom_metrics") }

    /// Same derivation again, swapping the trailing `/events` for `/infrastructure_metrics`.
    public var infrastructureMetricsURL: URL? { swappingEventsSuffix(for: "/infrastructure_metrics") }

    private func swappingEventsSuffix(for replacement: String) -> URL? {
        guard var components = parsedDSN() else { return nil }
        components.user = nil
        components.password = nil
        if components.path.hasSuffix("/events") {
            components.path = String(components.path.dropLast("/events".count)) + replacement
        }
        return components.url
    }

    /// Same derivation again, swapping the trailing `/events` for `/spans`.
    public var spansURL: URL? {
        guard var components = parsedDSN() else { return nil }
        components.user = nil
        components.password = nil
        if components.path.hasSuffix("/events") {
            components.path = String(components.path.dropLast("/events".count)) + "/spans"
        }
        return components.url
    }

    public var isEnabled: Bool {
        guard let dsn, !dsn.isEmpty, apiKey != nil else { return false }
        return enabledEnvironments.contains(environment)
    }
}
