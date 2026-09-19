import Foundation

/// The bounded, ordered trail of recent events `ForgeOpsTracker.addBreadcrumb` appends to,
/// attached to whatever gets reported next. Entries are plain dictionaries in the wire shape
/// (`category`/`message`/`level`/`timestamp`/`data`), the same "everything here is already a
/// dictionary" choice `EventBuilder` itself makes. Thread-safe: a mobile app adds breadcrumbs from
/// whatever thread happens to be running (main, a network callback, a background queue) into the
/// one shared trail, so every access here is serialized behind a lock. Ported from this repo's own
/// Objective-C client (`sdks/objc/Sources/ForgeOpsTracker/FOTBreadcrumbBuffer.h`), including the
/// one thing here with no counterpart in the server-side SDKs: persistence to disk.
///
/// Once `startPersisting()` is called (`ForgeOpsTracker.installHandlers()` does that), every
/// mutation schedules an asynchronous, atomic write of the (PII-scrubbed, when
/// `Configuration.scrubPII` is on) trail to a sibling file of the crash reports directory. A fatal
/// signal's handler can never safely read this in-memory trail (see `SignalHandler.swift`), and
/// the process it lived in is gone by the time the raw signal report uploads on the next launch,
/// so without a copy on disk the most common kind of crash would always report an empty trail. At
/// `startPersisting()` time, whatever the previous run left behind is read back first and held in
/// memory as the previous run's trail, before this run's own writes can replace it.
public final class BreadcrumbBuffer {
    private let configuration: Configuration
    private var entries: [[String: Any]] = []
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.forgeops.tracker.breadcrumbs")
    private var persisting = false
    private var previousRunEntries: [[String: Any]]?
    private var previousRunModifiedAt: Date?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// A sibling of the crash reports directory, not a file inside it: `CrashStore` treats every
    /// `.json`/`.txt` file in that directory as a pending crash report to upload.
    private var persistedPath: String {
        configuration.crashReportsDirectory + ".breadcrumbs.json"
    }

    /// Does nothing when `Configuration.trackBreadcrumbs` is false. Drops the oldest entries past
    /// `Configuration.maxBreadcrumbs`.
    public func add(message: String, category: String, level: String, data: [String: Any]) {
        guard configuration.trackBreadcrumbs else { return }

        let entry: [String: Any] = [
            "category": category,
            "message": message,
            "level": level,
            "timestamp": EventBuilder.iso8601Now(),
            "data": data,
        ]

        lock.lock()
        entries.append(entry)
        while entries.count > configuration.maxBreadcrumbs {
            entries.removeFirst()
        }
        lock.unlock()

        schedulePersist()
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()

        schedulePersist()
    }

    /// A copy of the current trail, oldest first.
    public func all() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Reads the previous run's persisted trail (if any) into memory, then begins persisting this
    /// run's. Idempotent.
    public func startPersisting() {
        lock.lock()
        let alreadyPersisting = persisting
        persisting = true
        lock.unlock()
        if alreadyPersisting { return }

        // Read whatever the previous run left behind before this run's first write can replace it.
        let path = persistedPath
        if let data = FileManager.default.contents(atPath: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !parsed.isEmpty,
           let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            lock.lock()
            previousRunEntries = parsed
            previousRunModifiedAt = modifiedAt
            lock.unlock()
        }

        schedulePersist()
    }

    /// The previous run's trail, if it could plausibly belong to a crash that happened at
    /// `crashDate`: the persisted file's last write must not be later than the crash itself, or a
    /// later run (one that didn't crash, or crashed differently) has already replaced the trail
    /// that crash left behind, and attaching it would be misleading rather than helpful. `nil`
    /// otherwise.
    public func previousRunBreadcrumbs(forCrashOccurringAt crashDate: Date) -> [[String: Any]]? {
        lock.lock()
        let entries = previousRunEntries
        let modifiedAt = previousRunModifiedAt
        lock.unlock()

        guard let entries, let modifiedAt else { return nil }
        // One second of slack: file timestamps aren't guaranteed finer-grained than that everywhere.
        if modifiedAt.timeIntervalSince(crashDate) > 1.0 { return nil }
        return entries
    }

    private func schedulePersist() {
        lock.lock()
        let shouldPersist = persisting
        let snapshot = entries
        lock.unlock()
        guard shouldPersist else { return }

        let scrub = configuration.scrubPII
        let path = persistedPath
        writeQueue.async {
            let toWrite: [[String: Any]] = snapshot.map { entry in
                guard scrub, let scrubbed = PiiScrubber.scrub(entry, key: nil) as? [String: Any] else { return entry }
                return scrubbed
            }
            // Best effort: never let breadcrumb persistence take down the host app.
            guard let json = try? JSONSerialization.data(withJSONObject: toWrite) else { return }
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? json.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Not part of the public API: blocks until every scheduled persistence write has finished
    /// (for tests).
    func _waitForPendingWrites() {
        writeQueue.sync {}
    }
}
