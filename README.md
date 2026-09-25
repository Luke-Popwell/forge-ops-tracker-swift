# ForgeOpsTracker (Swift)

Swift error/crash reporting client for [ForgeOps](https://getforgeops.net),
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
    .package(url: "https://github.com/Luke-Popwell/forge-ops-tracker-swift.git", from: "0.6.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["ForgeOpsTracker"])
]
```

Or in Xcode: File → Add Package Dependencies… → paste that URL.

That's a mirror, kept in sync automatically from `sdks/swift` in the main `forge_ops` repo (which
is private, so isn't itself something SPM could ever resolve directly): develop against that
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
    config.dsn = "https://<api_key>@getforgeops.net/api/v1/events"
    config.environment = "production"
}
ForgeOpsTracker.installHandlers()
```

## What gets reported automatically, and what doesn't

`installHandlers()` covers both mechanisms a Swift app on Apple platforms can actually crash
through:

- **An uncaught `NSException`**: `NSSetUncaughtExceptionHandler`, chained onto whatever handler
  (if any) was already installed rather than replacing it. A Swift app can still raise or receive
  an `NSException` any time it calls into Foundation or another Objective-C framework, since that
  exception model exists at the Objective-C runtime level, underneath Swift.
- **A fatal signal** (`SIGABRT`, `SIGILL`, `SIGSEGV`, `SIGFPE`, `SIGBUS`, `SIGTRAP`): installed via
  a small bundled C target (`CFOTSignal`), not pure Swift; see that target's own header comment for
  why: only async-signal-safe functions are safe to call inside an actual signal handler, and
  Swift's runtime (ARC retain/release on nearly every line of ordinary code) makes that guarantee
  far harder to reason about than a small, focused C implementation gives directly. A Swift
  `fatalError()` or a failed force-unwrap ultimately crashes through this same path, so both are
  covered too, with no Swift-specific handling needed.

**A plain Swift `Error` has no uncaught-error mechanism to hook at all.** Swift's `throws`/`catch`
is a completely different mechanism from Objective-C's exception model: a function that throws
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

## Identifying users

```swift
ForgeOpsTracker.capture(error: error, user: ["id": user.id, "email": user.email])
```

Or `setUser(_:)` to attach it to every subsequently reported error (an explicit `capture`/
`captureException` call, an uncaught `NSException`, a fatal signal) until changed or cleared,
rather than passing it to every call by hand, e.g. right after sign-in:

```swift
ForgeOpsTracker.setUser(["id": user.id, "email": user.email])
// on sign-out:
ForgeOpsTracker.setUser(nil)
```

There's no way to automatically detect "the current user" on iOS/macOS, so this is manual either
way. A mobile app install is effectively single-user (unlike a server handling many concurrent
requests at once), so this is a plain static property, not a thread-local. A fatal-signal crash
report is filled in with whoever is "current" at *upload* time (the next launch), not necessarily
who was signed in the moment it actually crashed: the signal handler itself can never safely read
this (see `CFOTSignal`'s own header comment on what's safe to touch there), the same "best effort,
filled in later" treatment that crash report's environment/release/server_name already get.
`id`/`email`/`username` are all independently optional. Shows up on an issue's own detail page,
and as its own affected-users count alongside the regular event count.

## Breadcrumbs

A small, bounded trail of recent events attached to whatever gets reported next, so an issue's
detail page can show what led up to it, not just the moment it happened:

```swift
ForgeOpsTracker.addBreadcrumb("charging card", category: "payment", data: ["orderId": order.id])
ForgeOpsTracker.addBreadcrumb("opened checkout") // category "custom", level "info"
```

Only the 30 most recent (`Configuration.maxBreadcrumbs`) are kept, oldest dropped first; turn it
off with `trackBreadcrumbs = false`. Safe to call from any thread. `message` and `data` are
PII-scrubbed like the rest of the payload, and the whole trail is omitted from the payload when
empty.

There's no request/controller lifecycle in a crash reporter to record one from automatically, so
every breadcrumb is one you add by hand. A mobile app is effectively single-flow, so there is one
shared trail (like `setUser(_:)`'s one shared user); call `ForgeOpsTracker.clearBreadcrumbs()` to
start a new logical unit of work (a new sign-in session, say) with a fresh one.

**A fatal signal keeps its breadcrumbs too.** A signal handler can't safely read the in-memory
trail, and the process is gone by the time its report uploads on the next launch, so once
`installHandlers()` has run the trail is also written to disk as it changes (PII-scrubbed, as a
sibling file of the crash reports directory), and the next launch attaches the previous run's trail
to that run's raw signal report. It's only attached when the trail's last write is not later than
the crash itself: if a later run has already replaced it, no trail is better than a misleading one.

## Performance monitoring

Times whatever you wrap and reports one small aggregate per transaction (how many times it ran,
total and maximum duration) every `Configuration.performanceFlushInterval` (60s by default), for the
Performance page's per-transaction table. Not one network call per timed call.

Each aggregate also carries a small latency histogram (a count per fixed latency bucket: 50, 100,
250, 500, 1000, 2500, 5000 and 10000ms, plus an overflow bucket), so ForgeOps can show an
approximate p50/p95/p99 per transaction, not just an average. Percentiles are accurate to the width
of whichever bucket a duration falls into; the SDK never stores the individual durations.

```swift
// Wrap a block; recorded even if it throws (the error propagates unchanged), and its value comes back:
let user = try ForgeOpsTracker.measureTransaction("load-user") { try loadUser(id) }

// Or record a duration you measured yourself, in milliseconds:
ForgeOpsTracker.recordPerformance("nightly-export", durationMs: elapsedMs)
```

This client has no web framework integration, so **nothing is timed automatically**: you choose what
to wrap. Keep transaction names low-cardinality (`"GET /users/:id"`, not `"GET /users/42"`): every
distinct name is its own row. Safe to call from any thread. Turn it off with `trackPerformance =
false`; it also does nothing (and starts no timer) when reporting isn't enabled for the current
environment.

The periodic flush is a `DispatchSourceTimer` on a private serial queue, started on the first
recorded duration. A dispatch source never keeps a process alive, so it can't hold a command-line
tool open. But an iOS app is suspended shortly after it goes to the background, and nothing is
flushed at exit (there is no normal exit to hook), so **call `ForgeOpsTracker.flushPerformance()`
yourself** from `applicationDidEnterBackground`/`sceneDidEnterBackground` (on a background queue if
you'd rather not block the main thread, since it's synchronous) or before a command-line tool quits,
or the last window is lost.

A failed delivery keeps every tally, so the next flush's window just grows. What a flush delivered
is *subtracted* from the tallies afterward, never the whole set cleared: a record from another
thread that lands while the network call is in flight (the lock is deliberately released around it)
would otherwise be silently discarded, a real bug `sdks/go` had and fixed and that
`gems/forge_ops_tracker`'s reference implementation still has. A deterministic test pins this.

## Distributed tracing

One flow's own call tree (a screen load, a sign-in, a network round trip and what it triggered),
shown as a span tree on ForgeOps. A trace is sent only when the whole flow took at least
`traceCaptureThreshold` seconds (1 by default), so fast flows cost nothing on the wire. A request
your app makes inside a trace can carry the trace on to your backend, so an error in the app links to
the backend request it caused (see "Connecting app errors to your backend" below).

```swift
ForgeOpsTracker.trace("load home screen") { trace in
    let feed = trace.measureSpan("fetch feed", kind: "http") { fetchFeed() }
    trace.measureSpan("decode", kind: "service", data: ["items": feed.count]) { decode(feed) }
}

// Or hold the trace across queues and finish it when the flow ends:
let trace = ForgeOpsTracker.startTrace("checkout")
DispatchQueue.global().async { trace.recordSpan("charge", kind: "http", startedAt: started, durationMs: ms) }
trace.finish()
```

Unlike the server SDKs, a mobile flow hops between the main queue and background queues, so a `Trace`
is an explicit object you pass around or capture in a closure, not ambient per-thread state, and it
is safe to use from any thread. Nesting is tracked per thread: a span opened by `measureSpan` is the
parent of any span recorded on the same thread inside its body, and a span recorded from another
thread parents under the root. `startTrace` returns `nil` when `trackTracing` is `false` or reporting
isn't enabled; `measureSpan`, `recordSpan` and `finish` are also defined on the optional, so callers
never unwrap. `kind` is one of `controller`, `service`, `database`, `redis`, `http`, `job`, `other`
(anything else is sent as `other`, since the server rejects a whole trace over one unknown kind).
`measureSpan` records even if its body throws, which propagates unchanged. A trace holds at most 500
spans.

This client has no web framework integration, so **nothing starts a trace or records a span
automatically**. Delivery runs on a private serial queue, bounded, off the calling thread. Nothing is
flushed at exit and an iOS app is suspended shortly after it backgrounds, so call
`ForgeOpsTracker.flushSpans()` (synchronous, on a background queue if you would rather not block the
main thread) from `applicationDidEnterBackground` or before a command-line tool quits. Turn the
feature off with `config.trackTracing = false`.

### Database spans with their SQL

A `database` span can carry the SQL it ran (a query against the app's local SQLite database, say)
and which database it was. Every string and number literal is replaced by `?` before it leaves the
device (so `WHERE email = 'a@b.co'` is sent as `WHERE email = ?`), the statement is cut at 4000
characters, and ForgeOps masks it again on arrival. It is sent in the span's data as `db.statement`
and `db.system`, and ForgeOps shows it on the span. Both parameters are ignored on any other kind.

```swift
let sql = "SELECT * FROM messages WHERE thread_id = 42 AND read = 0"
let messages = trace.measureSpan("Load messages", kind: "database", statement: sql, dbSystem: "sqlite") {
    try? database.query(sql)
}
// Sent as db.statement "SELECT * FROM messages WHERE thread_id = ? AND read = ?", db.system "sqlite".
```

`recordSpan` takes the same `statement:` and `dbSystem:` parameters for a query you timed yourself.

### Connecting app errors to your backend

Trace and span ids use the [W3C Trace Context](https://www.w3.org/TR/trace-context/) format (a 32
character lowercase hex trace id, 16 character span ids). Send a request through
`trace.measureRequest` and it goes out with a `traceparent` header
(`00-<trace id>-<span id>-01`) and is recorded as an `http` span named after its method and host;
the header's parent id is that span's own id, so the backend's own spans for the request nest under
it. An error captured with the trace carries its `trace_id`, which is what links it to the backend
error from the same request. A checkout flow:

```swift
func placeOrder(_ order: Order) async {
    let trace = ForgeOpsTracker.startTrace("checkout")
    defer { trace.finish() }

    var request = URLRequest(url: URL(string: "https://api.example.com/orders")!)
    request.httpMethod = "POST"
    request.httpBody = try? JSONEncoder().encode(order)

    do {
        let (_, response) = try await trace.measureRequest(request) { try await URLSession.shared.data(for: $0) }
        guard (response as? HTTPURLResponse)?.statusCode == 201 else { throw CheckoutError.rejected }
    } catch {
        ForgeOpsTracker.capture(error: error, context: ["order_id": order.id], trace: trace)
    }
}
```

The public API:

```swift
// On Trace (and on Trace?, where a nil trace sends the request unchanged and records nothing):
func measureRequest<T>(_ request: URLRequest, name: String? = nil, _ body: (URLRequest) throws -> T) rethrows -> T
func measureRequest<T>(_ request: URLRequest, name: String? = nil, _ body: (URLRequest) async throws -> T) async rethrows -> T
func startRequestSpan(_ request: URLRequest, name: String? = nil) -> RequestSpan
let traceId: String

// RequestSpan, for completion-handler code: send span.request, then call finish when it completes.
let request: URLRequest       // yours, plus the traceparent header when one was added
let spanId: String?
let traceparent: String?      // the header value added, for a transport that doesn't take a URLRequest
func finish(response: URLResponse? = nil, error: Error? = nil)

// Errors: trace links the event to it.
ForgeOpsTracker.capture(error:context:user:trace:)
ForgeOpsTracker.captureException(_:context:user:trace:)
```

`measureRequest` records the span even if `body` throws (the error propagates unchanged), and records
the status code when `body` returns a `URLResponse` or a `(Data, URLResponse)`/`(URL, URLResponse)`
pair, which is what `URLSession` returns. With completion handlers:

```swift
let span = trace.startRequestSpan(request)
URLSession.shared.dataTask(with: span.request) { data, response, error in
    span.finish(response: response, error: error)
    if let error { ForgeOpsTracker.capture(error: error, trace: trace) }
}.resume()
```

Inside the synchronous body of `ForgeOpsTracker.trace`, `measureSpan` or the synchronous
`measureRequest`, the trace is current on that thread, so a plain `ForgeOpsTracker.capture(error:)`
there carries its `trace_id` without passing it (and so does an uncaught `NSException` raised there).
Async code can resume on another thread, so pass `trace:` explicitly there. An error captured with no
trace has no `trace_id` and is exactly what it was before. A request that already has a
`traceparent` header is left alone. Nothing instruments `URLSession` automatically: only requests you
send through `measureRequest` or `startRequestSpan` get the header.

Two options control the header:

```swift
ForgeOpsTracker.configure { config in
    config.propagateTraces = true           // default; false stops the header (the http span is still recorded)
    config.tracePropagationTargets = nil    // default: every host
    // or only your own backends: a host matches exactly or as a subdomain on a dot boundary
    // ("example.com" matches "api.example.com", not "badexample.com"); .pattern is a regular
    // expression matched against the lowercased host
    config.tracePropagationTargets = ["example.com", .pattern(#"\.internal$"#)]
}
```

Narrow the targets when the app also calls third-party APIs that reject unknown headers or shouldn't
see your trace ids. To see the app error and the backend error together, the backend must also report
to ForgeOps (the Ruby SDK continues the trace from the header automatically as of 0.12.0) and the two
projects must be linked in ForgeOps.

## Custom metrics and infrastructure monitoring

Two explicit calls (nothing is automatic, so there is no `trackMetrics` flag): a business event you
name yourself, and a reading from one of your own hosts.

```swift
ForgeOpsTracker.captureMetric("signup")                 // value defaults to 1: a bare counter
ForgeOpsTracker.captureMetric("payment", value: 49)     // a real magnitude; it may be negative (a refund)

ForgeOpsTracker.captureInfrastructureMetric("cpu", value: 0.42)                     // hostname defaults to serverName
ForgeOpsTracker.captureInfrastructureMetric("disk", value: 0.81, hostname: "db-1")
ForgeOpsTracker.flushMetrics()                          // send right now
```

Each capture is buffered and flushed as one batch every `metricFlushInterval` /
`infrastructureMetricFlushInterval` (60 seconds by default) on a private serial queue, off the calling
thread. Nothing is flushed at exit and an iOS app is suspended shortly after it backgrounds, so call
`ForgeOpsTracker.flushMetrics()` (synchronous, on a background queue if you would rather not block the
main thread) from `applicationDidEnterBackground` or before a command-line tool quits. Every entry is
stored as it was captured (a signup is a row, not a running total), so a count or sum you compute later
is exact. Both are a no-op when reporting isn't enabled for the environment.

**Infrastructure readings need a hostname**, and an app has none by default: pass one, or set
`serverName` in `configure` (it is `nil` by default, and a reading without one is dropped with a log line rather than sent).

A failed delivery keeps every entry for the next flush, and an entry captured while a delivery is in
flight is kept too (the Ruby gem's own buffer loses it; a test pins this with a hook that captures at
exactly that moment). Each buffer holds at most 1000 entries and drops further ones until a flush
succeeds, since a plan without the feature rejects every flush and would otherwise grow it for as long
as the process lives. A NaN or infinite value is dropped at capture: `JSONSerialization` raises an
Objective-C exception for one, which Swift cannot catch, so it would crash the host app. Requires a
ForgeOps plan that includes custom metrics / infrastructure monitoring.

## Recording changes

When a feature flag flips or a remote config value changes, tell ForgeOps, and it shows the change on
the timeline next to the errors around it, so "crashes started right after `new_checkout` turned on"
is one glance instead of an investigation. Call `recordChange` from your flag or config client's
change callback:

```swift
import ForgeOpsTracker

ForgeOpsTracker.configure { config in
    config.dsn = "https://<api_key>@getforgeops.net/api/v1/events"
}

// Your flag client's change listener: whatever it calls with the key and the old and new values.
flagClient.onFlagChanged { key, oldValue, newValue in
    ForgeOpsTracker.recordChange(
        "feature_flag",
        title: "\(key) turned \(newValue ? "on" : "off")",
        details: ["key": key, "from": oldValue, "to": newValue],
        actor: "flag-service"
    )
}
```

`kind` is one of `"feature_flag"`, `"config"`, `"migration"`, `"dependency"`, `"infrastructure"`, or
`"other"`; anything else is sent as `"other"`. The title is required and cut to 200 characters.
Optional: `details` (a small JSON dictionary; one `JSONSerialization` can't encode, such as a NaN or a
`Date`, is left out rather than crashing the app), `environment` (defaults to the configured one),
`service`, `actor`, `url` (http or https), `id` (an idempotency key, so recording the same change twice
keeps one), and `occurredAt` (default now).

`recordChange` returns immediately and sends the change on a private serial queue, off the calling
thread (the main thread included). It never throws or crashes, whether the request fails or your plan
doesn't include change tracking (that 403 is silent), and it's a no-op when reporting isn't enabled for
the environment.

## Why upload happens on the *next* launch, not live during the crash

An uncaught `NSException`/fatal signal means the process is seconds (or less) from terminating,
possibly abnormally: there's no time, and no safe way, to make a live network call from inside
that handler. Instead, `Reporter` writes the event to disk (`CrashStore`, a small durable "queue"
that survives the process dying, rather than held live in memory) and `installHandlers()` uploads
whatever's pending from a background queue at the *next* app launch. A failed upload leaves the
file in place for the launch after that to retry.

## Backtrace frames: no file/line, ever

An `NSException`'s `-callStackSymbols` is a *binary symbol table* dump, not source locations:
there's no file/line the way a source-level language's exception carries, because that information
simply doesn't exist in a compiled, stripped release binary at runtime. Real line-level
symbolication needs an offline pass against the app's own dSYM after the fact (how native
crash reporters work): out of scope for a client SDK that has to
work standalone, with no external symbolication service to call. Backtrace frames here carry the
binary image name (closest available analog to "file") and the parsed symbol (closest analog to
"method"); `line` is always `null`. A signal-crash frame is even sparser: no file, no line, no
`in_app` classification at all: see `SignalHandler`'s own comment for why.

A `capture(error:)` call has a related but distinct limitation: a plain Swift `Error` carries no
backtrace of its own at all (nothing in the `Error` protocol captures one, unlike `NSException`,
which captures `-callStackReturnAddresses` at raise time). This uses `Thread.callStackSymbols`
captured at the `capture(error:)` call site instead: an approximation of where the error was
reported, not necessarily exactly where it was thrown.

## `in_app` backtrace frames

A frame is `in_app` only if its binary image name matches the running app's own executable name
(`Bundle.main.executablePath`): every system framework and every other loaded library is never
`in_app`, regardless of configuration. There's no `app_root`-style path comparison here, since
there are no source paths available at all in a compiled, stripped binary (see above).

## Source context

`Configuration.captureSourceContext` exists (defaulting to `true`, the same default every other SDK
in this repo uses) purely for API-shape consistency: a host app configuring this client sees the
same option every other SDK has. It does nothing here. Every other SDK in this repo that supports
it reads a few lines of source off disk around an in-app frame's culprit line at capture-time,
keyed off that frame's own file path and line number, but a backtrace frame here never carries a
real file path or line number at all, whether it came from `-callStackSymbols`,
`Thread.callStackSymbols`, or a signal-crash report (see "Backtrace frames: no file/line, ever"
above: `line` is always `null`, since a compiled, stripped release binary has no source location
left in it at runtime). `EventBuilder`'s underlying capture step is a documented no-op rather than
a partial implementation of something that can never actually run: there is no case, on this
client's capture path, where a real file+line pair exists to read.

## PII scrubbing

The message, backtrace, and any context you attach are scanned for likely personal data (email
addresses, formatted SSNs/credit cards, known API key/token formats, and anything under a
suspiciously-named key like `password`, `api_key`, or `ssn`) and redacted before the
payload ever leaves the device. ForgeOps itself scrubs again on arrival regardless, so this is a
second, earlier layer, not the only one. The user attached via `capture`/`captureException`'s
`user` parameter or `setUser` above is a deliberate exception: it's never scrubbed, since
redacting it would defeat the whole point of identifying users in the first place.

To disable it:

```swift
ForgeOpsTracker.configure { config in
    config.scrubPII = false
}
```

## An unguarded gap: an internal Foundation API raising NSException

Swift's `do`/`catch` cannot catch `NSException` at all (only a Swift `Error` thrown via `throw`),
so `Reporter` here has no way to guard against a Foundation API somehow raising an `NSException`
internally; an ordinary Objective-C message send can in principle do that even from
otherwise-unremarkable code, and there is no Swift-level mechanism available to catch it if it
happens. In practice this class only calls `try?`-guarded Foundation APIs (`JSONSerialization`,
`FileManager`) that surface failure as a thrown `Error`, not a raised `NSException`, so the
realistic exposure is low, but it's a real, documented gap, not a hypothetical one.

## Database errors

When an error carries the SQL behind a failed local database call, the event includes the names of the tables and views (and any stored procedure) that SQL touched, so the issue tells you where to start looking. This is on by default and sends identifiers only, never values. The statement is read by reflection from a `sql`, `statement` or `query` property on the error (GRDB's `DatabaseError.sql`), and from the error text GRDB and SQLite produce (`while executing ...`, `while compiling: ...`), including through `NSUnderlyingErrorKey`. Core Data exposes no statement.

To also send the SQL statement itself, opt in. Every string and number is replaced by `?` before it
leaves your process (`WHERE email = 'a@b.co' AND id = 42` is sent as `WHERE email = ? AND id = ?`),
and ForgeOps masks it again on arrival:

```swift
ForgeOpsTracker.configure { config in
    config.captureSqlStatement = true // default false
    // config.captureSqlObjects = false // default true; false stops even the names
}
```

Each ForgeOps project also has its own "Capture the SQL behind database errors" setting. Turn it off
there and the statement is never stored for that project, whatever this flag says; the names are
still kept. A view and a table are written the same way in SQL, so both show as tables/views; the
database's own error message usually settles which it was.

## Running the tests

```bash
cd sdks/swift
swift test
```

The test target links a small bundled Objective-C helper target (`CFOTTestSupport`), compiled as
part of this same Swift package: it raises and catches a real `NSException` so its
`-callStackSymbols` is actually populated, which Swift code cannot do directly, since Swift's
`do`/`catch` cannot catch `NSException` at all.
