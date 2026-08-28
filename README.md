# ForgeOpsTracker (Swift)

Swift error/crash reporting client for a private, self-hosted [ForgeOps](../../) tracker instance,
for iOS/macOS apps. Requires Swift 5.9+ (macOS 12+ / iOS 15+). Real-world Swift on Apple platforms
is overwhelmingly app code, not a web backend, so there's no server-side request-exception path for
this SDK to hook into. This SDK is instead a genuine crash reporter: it captures what would
otherwise crash the app, and uploads it on the next app launch rather than live. See "Why upload
happens on the *next* launch, not live during the crash" below for why that's a deliberate design
choice, not a limitation to work around.

## Installation

Swift Package Manager resolves straight from a git URL, no separate package index needed:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Luke-Popwell/forge-ops-tracker-swift.git", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["ForgeOpsTracker"])
]
```

Or in Xcode: File → Add Package Dependencies… → paste that URL.

That's a mirror, kept in sync automatically from `sdks/swift` in the main `forge_ops` repo (which
is private, so isn't itself something SPM could ever resolve directly) -- develop against that
repo, not this one. To build and run this SDK's own tests directly instead, or to add it as a
local package dependency during development:

```swift
// Package.swift
dependencies: [
    .package(path: "/path/to/forge_ops/sdks/swift")
]
```

## Configuration

Set a DSN (from a project's settings page in ForgeOps), as early as possible in app startup
(`application(_:didFinishLaunchingWithOptions:)` or your SwiftUI `App`'s `init`):

```swift
import ForgeOpsTracker

ForgeOpsTracker.configure { config in
    config.dsn = "https://<api_key>@your-forgeops-host/api/v1/events"
    config.environment = "production"
}
ForgeOpsTracker.installHandlers()
```

## What gets reported automatically, and what doesn't

`installHandlers()` covers both mechanisms a Swift app on Apple platforms can actually crash
through:

- **An uncaught `NSException`** -- `NSSetUncaughtExceptionHandler`, chained onto whatever handler
  (if any) was already installed rather than replacing it. A Swift app can still raise or receive
  an `NSException` any time it calls into Foundation or another Objective-C framework, since that
  exception model exists at the Objective-C runtime level, underneath Swift.
- **A fatal signal** (`SIGABRT`, `SIGILL`, `SIGSEGV`, `SIGFPE`, `SIGBUS`, `SIGTRAP`) -- installed via
  a small bundled C target (`CFOTSignal`), not pure Swift; see that target's own header comment for
  why: only async-signal-safe functions are safe to call inside an actual signal handler, and
  Swift's runtime (ARC retain/release on nearly every line of ordinary code) makes that guarantee
  far harder to reason about than a small, focused C implementation gives directly. A Swift
  `fatalError()` or a failed force-unwrap ultimately crashes through this same path, so both are
  covered too, with no Swift-specific handling needed.

**A plain Swift `Error` has no uncaught-error mechanism to hook at all.** Swift's `throws`/`catch`
is a completely different mechanism from Objective-C's exception model -- a function that throws
must always have its error handled or explicitly propagated by its caller, so there's no runtime
event corresponding to "an uncaught Swift error" the way `NSSetUncaughtExceptionHandler` exists for
`NSException`. Report one explicitly, right at the point you'd otherwise just log it:

```swift
do {
    try chargeCard(order)
} catch {
    ForgeOpsTracker.capture(error: error, context: ["order_id": order.id])
}
```

`captureException(_:context:)` is still available too, for an `NSException` you've caught yourself
(e.g. across an Objective-C boundary).

Both of these upload immediately (off the calling thread) rather than waiting for a crash report's
usual "next launch" path (see below), since the process didn't actually crash and there's no
particular reason to wait.

## Why upload happens on the *next* launch, not live during the crash

An uncaught `NSException`/fatal signal means the process is seconds (or less) from terminating,
possibly abnormally -- there's no time, and no safe way, to make a live network call from inside
that handler. Instead, `Reporter` writes the event to disk (`CrashStore`, a small durable "queue"
that survives the process dying, rather than held live in memory) and `installHandlers()` uploads
whatever's pending from a background queue at the *next* app launch. A failed upload leaves the
file in place for the launch after that to retry.

## Backtrace frames: no file/line, ever

An `NSException`'s `-callStackSymbols` is a *binary symbol table* dump, not source locations --
there's no file/line the way a source-level language's exception carries, because that information
simply doesn't exist in a compiled, stripped release binary at runtime. Real line-level
symbolication needs an offline pass against the app's own dSYM after the fact (how
Crashlytics/Sentry-cocoa-style crash reporters work) -- out of scope for a client SDK that has to
work standalone, with no external symbolication service to call. Backtrace frames here carry the
binary image name (closest available analog to "file") and the parsed symbol (closest analog to
"method"); `line` is always `null`. A signal-crash frame is even sparser: no file, no line, no
`in_app` classification at all -- see `SignalHandler`'s own comment for why.

A `capture(error:)` call has a related but distinct limitation: a plain Swift `Error` carries no
backtrace of its own at all (nothing in the `Error` protocol captures one, unlike `NSException`,
which captures `-callStackReturnAddresses` at raise time). This uses `Thread.callStackSymbols`
captured at the `capture(error:)` call site instead: an approximation of where the error was
reported, not necessarily exactly where it was thrown.

## `in_app` backtrace frames

A frame is `in_app` only if its binary image name matches the running app's own executable name
(`Bundle.main.executablePath`) -- every system framework and every other loaded library is never
`in_app`, regardless of configuration. There's no `app_root`-style path comparison here, since
there are no source paths available at all in a compiled, stripped binary (see above).

## PII scrubbing

The message, backtrace, and any context you attach are scanned for likely personal data -- email
addresses, formatted SSNs/credit cards, known API key/token formats, and anything under a
suspiciously-named key (`password`, `api_key`, `ssn`, and similar) -- and redacted before the
payload ever leaves the device. ForgeOps itself scrubs again on arrival regardless, so this is a
second, earlier layer, not the only one.

To disable it:

```swift
ForgeOpsTracker.configure { config in
    config.scrubPII = false
}
```

## An unguarded gap: an internal Foundation API raising NSException

Swift's `do`/`catch` cannot catch `NSException` at all -- only a Swift `Error` thrown via `throw` --
so `Reporter` here has no way to guard against a Foundation API somehow raising an `NSException`
internally; an ordinary Objective-C message send can in principle do that even from
otherwise-unremarkable code, and there is no Swift-level mechanism available to catch it if it
happens. In practice this class only calls `try?`-guarded Foundation APIs (`JSONSerialization`,
`FileManager`) that surface failure as a thrown `Error`, not a raised `NSException`, so the
realistic exposure is low -- but it's a real, documented gap, not a hypothetical one.

## Running the tests

```bash
cd sdks/swift
swift test
```

The test target links a small bundled Objective-C helper target (`CFOTTestSupport`), compiled as
part of this same Swift package: it raises and catches a real `NSException` so its
`-callStackSymbols` is actually populated, which Swift code cannot do directly, since Swift's
`do`/`catch` cannot catch `NSException` at all.
