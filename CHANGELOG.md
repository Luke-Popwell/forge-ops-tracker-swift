# Changelog

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
