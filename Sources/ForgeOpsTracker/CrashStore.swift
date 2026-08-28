import Foundation

/// Persists crash event payloads to disk and reads them back -- the "queue" for this SDK, in the
/// sense every other SDK's DeliveryQueue is its own queue, except this one survives the process
/// dying (which, for a crash reporter, is the one guarantee that actually matters: the app is
/// about to terminate, possibly abnormally, so anything not already durably written before that
/// happens is lost). Each payload is one JSON file under `Configuration.crashReportsDirectory`,
/// named by a UUID so concurrent writes (unlikely, but not impossible if multiple threads crash
/// near-simultaneously) never collide. Ported from this repo's own Objective-C client
/// (`sdks/objc/Sources/ForgeOpsTracker/FOTCrashStore.h`).
public final class CrashStore {
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

    /// The file URL of every pending payload currently on disk, oldest first.
    public func pendingPayloadURLs() -> [URL] {
        let dir = URL(fileURLWithPath: configuration.crashReportsDirectory, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }

        // Both extensions -- "json" is a full event payload written by Reporter after an uncaught
        // NSException/reported Error; "txt" is a raw signal-crash report written by the C signal
        // handler (see SignalHandler.swift's own comment for why that path can't safely build
        // JSON inline). Reporter.uploadPendingReports branches on which one it's looking at.
        let reportFiles = urls.filter { $0.pathExtension == "json" || $0.pathExtension == "txt" }
        return reportFiles.sorted { a, b in
            let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let dateA, let dateB else { return false }
            return dateA < dateB
        }
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
