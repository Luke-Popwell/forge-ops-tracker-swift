import Foundation

/// Public entry point. Typical usage, as early as possible in app startup
/// (`application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App`'s `init`):
///
///     ForgeOpsTracker.configure { config in
///         config.dsn = "https://<api_key>@your-forgeops-host/api/v1/events"
///         config.environment = "production"
///     }
///     ForgeOpsTracker.installHandlers()
///
/// See README.md for what `installHandlers` actually covers (an uncaught `NSException`, and the
/// common fatal signals -- the same two this repo's own Objective-C client covers) and what it
/// deliberately doesn't (this is a crash reporter, not a web framework's request-exception hook --
/// there's no equivalent to the Django/Express/Servlet-style integrations elsewhere in this repo,
/// since that's not how iOS/macOS apps are shaped), why a crash report always uploads on the
/// *next* launch rather than live during the crash itself, and -- new versus the Objective-C
/// client -- why nothing here is automatic for a plain Swift `Error`: report those explicitly via
/// `capture(error:context:)`.
public enum ForgeOpsTracker {
    private static var sharedConfiguration: Configuration?
    private static var sharedReporter: Reporter?
    private static var previousUncaughtExceptionHandler: NSUncaughtExceptionHandler?
    private static var handlersInstalled = false

    public static var configuration: Configuration {
        if sharedConfiguration == nil {
            sharedConfiguration = Configuration()
        }
        return sharedConfiguration!
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

        previousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            ForgeOpsTracker.reporter.report(exception: exception, context: nil)
            // Chain to whatever handler (if any) was already installed -- another crash reporter,
            // a debugger, or the host app's own -- rather than silently replacing it, the same
            // "rethrow, don't swallow" invariant every other framework integration in this repo
            // holds to.
            ForgeOpsTracker.previousUncaughtExceptionHandler?(exception)
        }

        SignalHandler.install(directory: configuration.crashReportsDirectory)

        // Deliberately not the main thread -- see Client's own comment on `deliver` being
        // synchronous; a background queue is what keeps that from ever blocking app launch.
        DispatchQueue.global(qos: .utility).async {
            reporter.uploadPendingReports()
        }
    }

    /// Report an exception you've already caught, e.g. from your own `@try`/`@catch` across an
    /// Objective-C boundary.
    public static func captureException(_ exception: NSException, context: [String: Any]? = nil) {
        reporter.report(exception: exception, context: context)
        uploadSoon()
    }

    /// Report a plain Swift `Error` you've already caught -- the common case for pure Swift code,
    /// since Swift has nothing equivalent to `NSException`/`NSSetUncaughtExceptionHandler` for its
    /// own `throws`/`catch` mechanism: an error a Swift function throws must always be handled or
    /// explicitly propagated by its caller, so there's no "uncaught Swift error" runtime event to
    /// hook the way there is for `NSException`.
    public static func capture(error: Error, context: [String: Any]? = nil) {
        reporter.report(error: error, context: context)
        uploadSoon()
    }

    private static func uploadSoon() {
        // Unlike an uncaught exception/fatal signal, this one didn't crash the process -- upload
        // now rather than waiting for a next launch that (having not crashed) has no particular
        // reason to come soon. Still off the calling thread, for the same reason as
        // installHandlers above.
        DispatchQueue.global(qos: .utility).async {
            reporter.uploadPendingReports()
        }
    }

    /// Not part of the public API -- resets module state between test cases.
    static func _resetForTesting() {
        sharedConfiguration = nil
        sharedReporter = nil
        handlersInstalled = false
        // Deliberately not touching the real NSUncaughtExceptionHandler/signal dispositions here
        // -- resetting those between test runs would risk leaving the *test process itself*
        // without a safety net if a later, unrelated test genuinely crashes. Same reasoning as
        // this repo's own Objective-C client's own _resetForTesting.
    }
}
