import Foundation

/// Persists crash event payloads to disk and reads them back: the "queue" for this SDK, in the
/// sense every other SDK's DeliveryQueue is its own queue, except this one survives the process
/// dying (which, for a crash reporter, is the one guarantee that actually matters: the app is
/// about to terminate, possibly abnormally, so anything not already durably written before that
/// happens is lost). Each payload is one JSON file under `Configuration.crashReportsDirectory`,
/// named by a UUID so concurrent writes (unlikely, but not impossible if multiple threads crash
/// near-simultaneously) never collide. Ported from this repo's own Objective-C client
/// (`sdks/objc/Sources/ForgeOpsTracker/FOTCrashStore.h`).
public final class CrashStore {
    /// The most pending reports kept on disk, and the longest one is kept: a report that keeps
    /// failing to upload (see `Reporter.uploadPendingReports`) must not pile up or be retried for good.
    public static let maxPendingPayloads = 20
    public static let maxPendingPayloadAge: TimeInterval = 7 * 24 * 60 * 60

    private let configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Writes payload to disk synchronously. Returns false (and never throws) if the write fails
    /// for any reason.
    @discardableResult
    public func write(payload: [String: Any]) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: configuration.crashReportsDirectory, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: payload)
            let filename = UUID().uuidString + ".json"
            let path = (configuration.crashReportsDirectory as NSString).appendingPathComponent(filename)
            try json.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The file URL of every pending payload currently on disk, oldest first. Anything older than
    /// `maxPendingPayloadAge`, and the oldest beyond `maxPendingPayloads`, is deleted here first.
    public func pendingPayloadURLs() -> [URL] {
        let dir = URL(fileURLWithPath: configuration.crashReportsDirectory, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }

        // Both extensions: "json" is a full event payload written by Reporter after an uncaught
        // NSException/reported Error; "txt" is a raw signal-crash report written by the C signal
        // handler (see SignalHandler.swift's own comment for why that path can't safely build
        // JSON inline). Reporter.uploadPendingReports branches on which one it's looking at.
        let reportFiles = urls.filter { $0.pathExtension == "json" || $0.pathExtension == "txt" }
        let sorted = reportFiles.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let dateA, let dateB else { return false }
            return dateA < dateB
        }
        return prune(sorted)
    }

    // A file whose creation date can't be read is never counted as too old, only toward the cap.
    private func prune(_ sorted: [URL]) -> [URL] {
        let cutoff = Date().addingTimeInterval(-CrashStore.maxPendingPayloadAge)
        var kept: [URL] = []
        var expired = 0
        for url in sorted {
            if let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate, created < cutoff {
                deletePayload(at: url)
                expired += 1
            } else {
                kept.append(url)
            }
        }

        let excess = max(0, kept.count - CrashStore.maxPendingPayloads)
        for url in kept.prefix(excess) {
            deletePayload(at: url)
        }
        kept.removeFirst(excess)

        if expired > 0 {
            NSLog("[forge-ops-tracker] dropped %ld crash reports older than 7 days that could not be delivered", expired)
        }
        if excess > 0 {
            NSLog("[forge-ops-tracker] dropped the %ld oldest crash reports: more than %ld were waiting to be delivered", excess, CrashStore.maxPendingPayloads)
        }
        return kept
    }

    public func payload(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return parsed
    }

    public func deletePayload(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
