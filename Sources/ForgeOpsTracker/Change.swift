import Foundation

/// Builds the `POST /api/v1/changes` body for `ForgeOpsTracker.recordChange`. Separate from the
/// facade so the payload shape can be tested without a network round trip.
enum Change {
    /// The kinds the changes endpoint accepts; anything else is sent as `"other"` rather than
    /// rejected by the server.
    static let kinds: Set<String> = ["feature_flag", "config", "migration", "dependency", "infrastructure", "other"]

    /// The server's own limit on a title; a longer one is truncated here instead of rejected there.
    static let maxTitleLength = 200

    static func normalizedKind(_ kind: String) -> String {
        kinds.contains(kind) ? kind : "other"
    }

    /// `nil` for a change with no title, the one field the server can't do without. `details` that
    /// `JSONSerialization` can't encode (a NaN, a `Date`, any non-JSON type) are left out rather than
    /// sent: encoding one raises an Objective-C exception, which Swift can't catch, so it would crash
    /// the host app.
    static func payload(
        kind: String,
        title: String,
        details: [String: Any]?,
        environment: String?,
        service: String?,
        actor: String?,
        url: String?,
        id: String?,
        occurredAt: Date?,
        configuration: Configuration
    ) -> [String: Any]? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var payload: [String: Any] = [
            "kind": normalizedKind(kind),
            "title": String(trimmed.prefix(maxTitleLength)),
            "environment": environment ?? configuration.environment,
            "occurred_at": iso8601(occurredAt ?? Date()),
        ]
        if let details, JSONSerialization.isValidJSONObject(details) {
            payload["details"] = details
        }
        if let service, !service.isEmpty { payload["service"] = service }
        if let actor, !actor.isEmpty { payload["actor"] = actor }
        if let url, let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            payload["url"] = url
        }
        if let id, !id.isEmpty { payload["id"] = id }
        return payload
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
