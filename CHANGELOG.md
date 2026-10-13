# Changelog

## 0.8.0 (2026-10-13)

- A delivery the server will never accept is no longer sent again and again. A response of 4xx
  (other than 408 and 429) now means the payload is let go: a crash report file is deleted, and a
  batch of performance samples, metrics or infrastructure readings is dropped. A network error, a
  timeout, a 5xx, 408 or 429 still keeps the payload for a later try, but not for good: a batch is
  dropped after five failed flushes in a row, at most 20 crash reports wait on disk (the oldest
  beyond that are deleted), and a crash report older than 7 days is deleted. Each drop is logged
  once with `NSLog`, saying what was dropped and why. Before, any failure kept the payload, so a
  rejected crash report was uploaded at every launch and a rejected batch at every flush. New
  `CrashStore.maxPendingPayloads` and `CrashStore.maxPendingPayloadAge`. No public API changed:
  every `Client.deliver*` still returns `true` only for a 2xx.

## 0.7.1 (2026-10-07)

- The package now ships its MIT licence (`LICENSE.txt`). Earlier versions were published without one. No code changes.

## 0.7.0 (2026-09-29)

- SQL masking now catches values it used to let through, matching ForgeOps's own masker again: a
  string with a backslash-escaped quote (`'o\'brien'`, `E'o\'brien'`) is masked whole instead of
  leaving the rest of it visible, a string's type prefix goes with it (`E''`, `X''`, `N''`, `B''`
  and `U&''` each become one `?`), and hex (`0x1F`), binary (`0b101`), exponent (`3e10`, `1.5E-3`)
  and leading-dot (`.5`) numbers are masked. On a `database` span whose `dbSystem` is `mysql` or
  `mariadb`, "double quoted" text is a string and is masked too; on any other database it's a name
  and is still left alone. Digits and letters next to a value are now judged by ASCII only, the way
  the server does, so a number right after an accented letter is masked the same on both sides.

## 0.6.0 (2026-09-25)

- A `database` span can now carry the SQL it ran, such as a local SQLite query: pass `statement:`
  (and optionally `dbSystem:`, such as `"sqlite"`) to `measureSpan` or `recordSpan`. The statement is
  masked on the device (every string and number literal becomes `?`), cut at 4000 characters, and
  sent in the span's data as `db.statement`, with `db.system` lowercased. A `db.statement` put in
  `data` directly is masked the same way. Both are ignored on spans of any other kind.

## 0.5.0 (2026-09-25)

- New `ForgeOpsTracker.recordChange(_:title:details:environment:service:actor:url:id:occurredAt:)`
  tells ForgeOps what changed in your app, typically from a feature flag or remote config change
  callback, so the change shows on the timeline next to the errors around it. `kind` is one of
  feature_flag, config, migration, dependency, infrastructure, or other (anything else is sent as
  other). Sent to `/api/v1/changes` on a private serial queue, off the calling thread; it never throws
  or crashes, a failed request or a plan without change tracking is silent, and it's a no-op when
  reporting isn't enabled. New `Configuration.changesURL` and `Client.deliverChange`.

This package has earlier tagged releases, but no `CHANGELOG.md` existed for it before this entry; it
starts here without backfilling every earlier version.
