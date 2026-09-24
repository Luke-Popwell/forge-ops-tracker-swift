import Foundation

/// Ties Configuration, EventBuilder, and CrashStore together. Mirrors every other SDK's own
/// Reporter/ErrorSubscriber in spirit: split into two halves (capture now, upload later) rather
/// than one `report()` call, because a crash reporter's two real responsibilities happen at two
/// different, unrelated moments: the crash itself (capture, write to disk, nothing else: see
/// EventBuilder's own comment for why a live network call has no place here), and the *next* app
/// launch (read whatever's pending, try to upload it, same as any other SDK's own delivery).
/// Ported from this repo's own Objective-C client (`sdks/objc/Sources/ForgeOpsTracker/FOTReporter.h`).
///
/// One honest limitation this repo's Objective-C client doesn't have: `report`/`uploadPendingReports`
/// there are wrapped in `@try`/`@catch`, since an ordinary Objective-C message send can in principle
/// raise `NSException` even from otherwise-unremarkable code. Swift's `do`/`catch` cannot catch
/// `NSException` at all (only a Swift `Error` thrown via `throw`) so if a Foundation API this
/// class calls into somehow raised an `NSException` internally, nothing here could stop it from
/// propagating. In practice this class only calls `try?`-guarded Foundation APIs (`JSONSerialization`,
/// `FileManager`) that surface failure as a thrown `Error`, not a raised `NSException`, so the
/// realistic exposure is low, but it's not the same hard guarantee the Objective-C client makes.
public final class Reporter {
    private let configuration: Configuration
    private let crashStore: CrashStore
    private let client: Client

    // client is injectable purely so tests can hand this a Client wired to a stubbed
    // URLProtocol (see ClientTests/ReporterTests): every real use leaves it nil and gets an
    // ordinary Client.
    public init(configuration: Configuration, client: Client? = nil) {
        self.configuration = configuration
        crashStore = CrashStore(configuration: configuration)
        self.client = client ?? Client(configuration: configuration)
    }

    /// Called from the uncaught exception handler (or explicitly, for a caught-but-notable
    /// exception).
    public func report(exception: NSException, context: [String: Any]?, user: [String: Any]? = nil, breadcrumbs: [[String: Any]]? = nil, traceId: String? = nil) {
        guard configuration.isEnabled else { return }
        let payload = EventBuilder.buildEvent(exception: exception, configuration: configuration, context: context, user: user, breadcrumbs: breadcrumbs, traceId: traceId)
        crashStore.write(payload: payload)
    }

    /// Called for a plain Swift `Error` you've already caught.
    public func report(error: Error, context: [String: Any]?, user: [String: Any]? = nil, breadcrumbs: [[String: Any]]? = nil, traceId: String? = nil) {
        guard configuration.isEnabled else { return }
        let payload = EventBuilder.buildEvent(error: error, configuration: configuration, context: context, user: user, breadcrumbs: breadcrumbs, traceId: traceId)
        crashStore.write(payload: payload)
    }

    /// Uploads every pending crash report left over from a previous launch, deleting each on
    /// success and leaving a failed one in place for the next attempt. Deliberately synchronous:
    /// call this from a background queue at startup, not the main thread.
    public func uploadPendingReports() {
        guard configuration.isEnabled else { return }

        for url in crashStore.pendingPayloadURLs() {
            let payload: [String: Any]?
            if url.pathExtension == "txt" {
                // A raw signal-crash report: fill in the standard fields the C signal handler
                // couldn't safely build inline (see SignalHandler.swift), now that it's safe to
                // use Foundation freely again.
                payload = SignalHandler.parseRawSignalReport(at: url).map { completeSignalPayload($0, reportURL: url) }
            } else {
                payload = crashStore.payload(at: url)
            }

            guard let payload else {
                // Unreadable/corrupt file: delete rather than retry forever.
                crashStore.deletePayload(at: url)
                continue
            }
            if client.deliver(payload) {
                crashStore.deletePayload(at: url)
            }
            // On failure, leave it in place; the next launch's uploadPendingReports retries it.
        }
    }

    private func completeSignalPayload(_ parsed: [String: Any], reportURL: URL) -> [String: Any] {
        var payload = parsed
        // Upload time, not crash time: the raw file has no safely-capturable timestamp of its
        // own beyond its filename. The current user is the same story: a signal handler can't
        // safely read arbitrary Swift state (see SignalHandler.swift's own comment on what it
        // can and can't touch), so this reads ForgeOpsTracker.currentUser here instead, well
        // after the signal itself, now that it's safe to use Foundation/Swift freely again. This
        // means a signal crash always reports whoever is "current" at *upload* time, not
        // necessarily who was signed in at the moment of the actual crash; an accepted
        // imprecision, the same "best effort, not exact" spirit this whole raw-signal path
        // already has for everything else it fills in here.
        payload["occurred_at"] = EventBuilder.iso8601Now()
        payload["environment"] = configuration.environment
        payload["release"] = configuration.releaseVersion as Any? ?? NSNull()
        payload["server_name"] = configuration.serverName as Any? ?? NSNull()
        payload["context"] = [String: Any]()
        payload["tags"] = [String: Any]()
        if let user = ForgeOpsTracker.currentUser, !user.isEmpty {
            payload["user"] = user
        }

        // The trail the *crashed* run left behind on disk (see BreadcrumbBuffer): this process's
        // own in-memory trail only starts after the crash, so it has nothing to say about it. Only
        // attached when it plausibly belongs to this specific crash, judged by the raw report
        // file's own creation time; already PII-scrubbed when it was written, so not scrubbed
        // again here.
        if let crashDate = (try? reportURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
           let breadcrumbs = ForgeOpsTracker.previousRunBreadcrumbs(forCrashOccurringAt: crashDate),
           !breadcrumbs.isEmpty {
            payload["breadcrumbs"] = breadcrumbs
        }
        return payload
    }
}
