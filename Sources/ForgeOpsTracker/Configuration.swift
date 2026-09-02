import Foundation

/// Holds a single ForgeOps DSN plus everything else the client needs to build and deliver events.
/// Mirrors `gems/forge_ops_tracker/lib/forge_ops_tracker/configuration.rb` (a single DSN string
/// carries both the ingestion URL and the project's api_key:
/// "https://<api_key>@host/api/v1/events") and this repo's own Objective-C client
/// (`sdks/objc/Sources/ForgeOpsTracker/FOTConfiguration.h`) -- parsed with `URLComponents` rather
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
    /// SDK in this repo -- see `EventBuilder`'s own top comment for why this specific client's
    /// capture path is a documented no-op regardless of this value: neither `-callStackSymbols` nor
    /// `Thread.callStackSymbols` ever produces a real file+line pair to read in the first place.
    public var captureSourceContext: Bool = true

    /// Where pending (not-yet-uploaded) crash reports are written -- see CrashStore.
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

    public var isEnabled: Bool {
        guard let dsn, !dsn.isEmpty, apiKey != nil else { return false }
        return enabledEnvironments.contains(environment)
    }
}
