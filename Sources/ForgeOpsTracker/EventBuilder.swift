import Foundation

/// Builds the payload shape the ingestion API expects, from either an `NSException` (Objective-C
/// interop: see this repo's own Objective-C client, `sdks/objc/.../FOTEventBuilder.h`, for the
/// full rationale on why an exception's backtrace carries binary image name + symbol rather than
/// file/line) or a plain Swift `Error`.
///
/// A plain Swift `Error` is a new case this repo's Objective-C client doesn't have to handle:
/// Swift's `Error` protocol carries no backtrace of its own (nothing else in this repo's iOS/macOS
/// client needs one either, since `NSException` already captures `-callStackReturnAddresses` at
/// raise time): so for a Swift `Error`, this uses `Thread.callStackSymbols` captured at the
/// `capture(error:)` call site instead. That's an approximation of where the error was reported,
/// not necessarily exactly where it was thrown, the same limitation this repo's Rust and Go
/// clients document for their own "no stack on the error value itself" languages.
/// No source context, ever: every other SDK in this repo (that has real file/line info at all)
/// attaches a few lines of source around an in-app frame's culprit line, read off disk at
/// capture-time. That needs a real file path and line number to key the disk read off of, and
/// neither `backtrace(forCallStackSymbols:)` below nor `SignalHandler.parseRawSignalReport` ever
/// produces one: every frame's `"line"` is `NSNull()`. `Configuration.captureSourceContext` still
/// exists, defaulting to `true` like every other SDK, purely so a host app configuring this client
/// sees the same option every other SDK has; `attachSourceContext(to:)` is a documented no-op, not
/// a partial implementation of something that can never actually run on this SDK's capture path.
public enum EventBuilder {
    static let maxFrames = 500

    // Would be the source-context window size and per-line truncation length (see other SDKs' own
    // EventBuilder for the real version of this), if a frame here ever carried a real file+line
    // pair to key a disk read off of. It doesn't (see this type's own top comment) so these
    // exist unused here purely as a documented placeholder, named consistently with maxFrames
    // above, rather than silently having no trace of the concept at all.
    static let contextLines = 5
    static let maxContextLineLength = 500

    // Identifies this client to the server's auto language-detection on the project the event
    // lands in (see Project#note_sdk_platform server-side); matches this repo's own sdks/swift
    // directory name, the same convention every other language's client follows.
    static let sdkName = "swift"

    // e.g. "12  MyApp    0x0000000100abcd12 -[MyClass myMethod] + 82": frame index, image name,
    // address, symbol, "+ offset". Same shape as this repo's own Objective-C client's own
    // FOTFrameRegex: verified there directly against real -callStackSymbols output before
    // relying on it, not assumed from Apple's own (informal, undocumented) format alone.
    private static let frameRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(pattern: #"^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)\s+\+\s+\d+\s*$"#) else {
            fatalError("failed to compile frame regex")
        }
        return regex
    }()

    public static func buildEvent(exception: NSException, configuration: Configuration, context: [String: Any]?, user: [String: Any]? = nil, breadcrumbs: [[String: Any]]? = nil) -> [String: Any] {
        buildEvent(
            exceptionClass: exception.name.rawValue,
            message: exception.reason ?? "",
            backtrace: backtrace(forCallStackSymbols: exception.callStackSymbols),
            sqlStatement: SqlStatement.findIn(exception: exception),
            configuration: configuration,
            context: context,
            user: user,
            breadcrumbs: breadcrumbs
        )
    }

    public static func buildEvent(error: Error, configuration: Configuration, context: [String: Any]?, user: [String: Any]? = nil, breadcrumbs: [[String: Any]]? = nil) -> [String: Any] {
        let nsError = error as NSError
        return buildEvent(
            exceptionClass: String(describing: type(of: error)),
            message: (error as? LocalizedError)?.errorDescription ?? nsError.localizedDescription,
            backtrace: backtrace(forCallStackSymbols: Thread.callStackSymbols),
            sqlStatement: SqlStatement.findIn(error: error),
            configuration: configuration,
            context: context,
            user: user,
            breadcrumbs: breadcrumbs
        )
    }

    // user is deliberately kept out of the dictionary PiiScrubber.scrub(payload, key: nil) below
    // actually runs over, not merged in beforehand: unlike every other SDK's own per-field scrub
    // call, this one recurses over the *whole* payload dict by value pattern alone (no key-name
    // exemption list for exception_class/environment/etc., see that function's own doc comment),
    // so a "user" key present at scrub time would have its own email value redacted by the exact
    // same EMAIL pattern that's supposed to leave it alone. Adding it back in afterward, once
    // scrubbing has already run on everything else, is what keeps it a deliberate exemption
    // rather than an oversight: the whole point of this field is that it's deliberately
    // identifiable, not something to redact.
    private static func buildEvent(exceptionClass: String, message: String, backtrace: [[String: Any]], sqlStatement: String?, configuration: Configuration, context: [String: Any]?, user: [String: Any]?, breadcrumbs: [[String: Any]]?) -> [String: Any] {
        var payload: [String: Any] = [
            "exception_class": exceptionClass,
            "message": message,
            "backtrace": backtrace,
            "occurred_at": iso8601Now(),
            "environment": configuration.environment,
            "release": configuration.releaseVersion as Any? ?? NSNull(),
            "server_name": configuration.serverName as Any? ?? NSNull(),
            "context": context ?? [:],
            "tags": [String: Any](),
            "sdk_name": sdkName,
        ]
        // Omitted entirely (never sent as an empty array) when there's nothing to report. Goes
        // through PiiScrubber along with everything else in the payload: that scrubber has no
        // per-field exemption list at all (see the user note above), and a breadcrumb's structured
        // category/level/timestamp values never match any of its patterns in practice, so the same
        // blanket treatment is the consistent choice here rather than a carve-out of its own.
        if let breadcrumbs, !breadcrumbs.isEmpty {
            payload["breadcrumbs"] = breadcrumbs
        }
        // See SqlStatement for what's read off the error and how it's masked. The statement itself
        // only goes out when captureSqlStatement is on; the extracted names go out on their own
        // (captureSqlObjects) so an issue can still name the table or view involved. Scrubbed with
        // everything else below, like the rest of the payload.
        if configuration.captureSqlObjects || configuration.captureSqlStatement,
           let masked = SqlStatement.mask(sqlStatement) {
            if configuration.captureSqlObjects, let objects = SqlStatement.objects(masked) {
                payload["sql_objects"] = objects
            }
            if configuration.captureSqlStatement {
                payload["sql_statement"] = masked
            }
        }

        var result: [String: Any]
        if configuration.scrubPII, let scrubbed = PiiScrubber.scrub(payload, key: nil) as? [String: Any] {
            result = scrubbed
        } else {
            result = payload
        }

        if let user, !user.isEmpty {
            result["user"] = user
        }
        return result
    }

    private static func backtrace(forCallStackSymbols symbols: [String]) -> [[String: Any]] {
        var frames: [[String: Any]] = []
        for line in symbols {
            if frames.count >= maxFrames { break }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = frameRegex.firstMatch(in: line, options: [], range: range),
                  let imageRange = Range(match.range(at: 1), in: line),
                  let symbolRange = Range(match.range(at: 2), in: line)
            else {
                continue // an unparseable line is skipped, not an error: see PHP's own client for the same philosophy
            }

            let image = String(line[imageRange])
            let symbol = String(line[symbolRange])
            frames.append(attachSourceContext(to: [
                "file": image,
                "line": NSNull(), // no line-level info at runtime: see this file's own top comment
                "method": symbol,
                "in_app": isInApp(image: image),
            ]))
        }
        return frames
    }

    /// Deliberately a no-op: see this type's own top comment. The gating logic every other SDK
    /// applies here is: the config option is on, AND the frame is in-app, AND a real file path +
    /// line number is actually available. The third condition can never be true on this SDK's own
    /// capture path: `callStackSymbols` gives a binary image name and a resolved symbol, never a
    /// source file or a line number (`frame["line"]` above is always `NSNull()`): so there is
    /// nothing `Configuration.captureSourceContext` could ever gate here even though it exists (see
    /// `Configuration`'s own comment) for API-shape consistency with every other SDK. No disk read
    /// is ever attempted, regardless of what that flag is set to.
    private static func attachSourceContext(to frame: [String: Any]) -> [String: Any] {
        frame
    }

    private static func isInApp(image: String) -> Bool {
        guard let executableName = (Bundle.main.executablePath as NSString?)?.lastPathComponent else {
            return false
        }
        return image == executableName
    }

    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
