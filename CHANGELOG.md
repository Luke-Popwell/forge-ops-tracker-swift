# Changelog

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
