import CFOTSignal
import Foundation

/// Installs the fatal-signal handlers (SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP) via the
/// small bundled C target (CFOTSignal) rather than a pure-Swift implementation -- see that
/// target's own header comment for why: inside a real signal handler, only async-signal-safe
/// functions are safe to call, and Swift's runtime (ARC retain/release on nearly every line of
/// ordinary code, dynamic dispatch, potential allocation for String/Array) makes that guarantee
/// far harder to reason about than in the small, already-proven C implementation this repo's own
/// Objective-C client already ships (`sdks/objc/Sources/ForgeOpsTracker/FOTSignalHandler.m`).
/// Reading the resulting file back (`parseRawSignalReport`, below) happens on the *next* launch,
/// in ordinary safe Swift/Foundation code -- only the moment of the crash itself needs the C path.
public enum SignalHandler {
    public static func install(directory: String) {
        // Creating the directory is ordinary, safe Foundation code -- done here, before handing
        // control to the C side, rather than inside the signal handler itself.
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        cfot_install_signal_handlers(directory)
    }

    /// Reads a raw signal-crash text file (written by `cfot_signal.c`) back into event-shaped
    /// fields.
    public static func parseRawSignalReport(at url: URL) -> [String: Any]? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var lines = contents.components(separatedBy: "\n")
        let signalName = lines.isEmpty ? "unknown signal" : lines.removeFirst()

        var backtrace: [[String: Any]] = []
        for line in lines where !line.isEmpty {
            backtrace.append([
                "file": NSNull(),
                "line": NSNull(),
                "method": line,
                "in_app": false, // signal-handler frames aren't classified -- see this type's own comment
            ])
        }

        return [
            "exception_class": "Signal: \(signalName)",
            "message": "Uncaught fatal signal: \(signalName)",
            "backtrace": backtrace,
        ]
    }
}
