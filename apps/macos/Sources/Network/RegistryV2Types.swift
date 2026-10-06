// RegistryV2Types.swift — Lane B (Track B / Python daemon) contract for
// the v0.2 Claude Code toast pipeline.
//
// Contract (per docs/v0.2-plan/01-feature-stories.md S08 and the Track A
// brief):
//
//   POST /v2/registry/announce   body: RegistryAnnounceRequest
//      → daemon adds a pending item, returns its id
//
//   GET  /v2/registry/list       returns RegistryListResponse
//      → { pending: [ RegistryV2Item ] }
//
//   POST /v2/registry/play/{id}  optional body: RegistryPlayRequest
//      → daemon kicks off playback; { ok: bool, reason?: string }
//
// This file is the SOURCE OF TRUTH for the Swift side of this contract.
// Track B implements the matching Python types in `daemon/myna/v2_types.py`
// (or wherever they choose to house them).
//
// Pre-merge with Track B, the Lane A app uses `MenuBarController` to fall
// back to the v1 `/registry` data exposed inside `/v2/status.registry`,
// so the menu bar's "Claude Code ▸" submenu still shows announcements
// from the existing pipeline. The toast feature requires the new
// endpoints to be live (otherwise registryListV2 returns 404 → no toasts).
import Foundation

public struct RegistryV2Item: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let source: String  // "claude-code" | "manual" | ...
    public let projectId: String  // stable project key for the palette hash
    public let title: String  // preview text (≤ ~80 chars)
    /// Full reply body. `title` is only the first-line preview; play this so
    /// the WHOLE output is read, not just the opening sentence. Optional —
    /// nil for entries announced before the daemon carried it (callers fall
    /// back to `title`). See `spokenText`.
    public let text: String?
    public let announcedAtMs: Int  // unix ms timestamp
    public let ttlS: Int  // suggested time-to-live in seconds
    // Claude Code hands-free fields. All optional: daemons before Sep 2026
    // don't send them, and nil reads as a plain reply.
    /// "reply" (Stop hook) or "attention" (Notification hook: a session needs you).
    public let kind: String?
    /// Claude Code session the entry came from.
    public let sessionId: String?
    /// Attention only: Claude Code's notification_type, e.g. "permission_prompt".
    public let notificationType: String?
    /// Bundle id of the app the session runs in (iTerm, Terminal, VS Code…).
    public let hostBundleId: String?
    /// The unheard rest of a reply Myna began reading aloud while you were away.
    public let partlyHeard: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case projectId = "project_id"
        case title
        case text
        case announcedAtMs = "announced_at_ms"
        case ttlS = "ttl_s"
        case kind
        case sessionId = "session_id"
        case notificationType = "notification_type"
        case hostBundleId = "host_bundle_id"
        case partlyHeard = "partly_heard"
    }

    public init(
        id: String,
        source: String,
        projectId: String,
        title: String,
        text: String? = nil,
        announcedAtMs: Int,
        ttlS: Int,
        kind: String? = nil,
        sessionId: String? = nil,
        notificationType: String? = nil,
        hostBundleId: String? = nil,
        partlyHeard: Bool? = nil
    ) {
        self.id = id
        self.source = source
        self.projectId = projectId
        self.title = title
        self.text = text
        self.announcedAtMs = announcedAtMs
        self.ttlS = ttlS
        self.kind = kind
        self.sessionId = sessionId
        self.notificationType = notificationType
        self.hostBundleId = hostBundleId
        self.partlyHeard = partlyHeard
    }

    /// True for a Notification-hook entry ("a session needs you"), false for a reply.
    public var isAttention: Bool { kind == "attention" }

    /// The text to actually speak: the full body when present, else the
    /// first-line preview. Never empty-coalesces away a real title.
    public var spokenText: String {
        if let text = text, !text.isEmpty { return text }
        return title
    }

    /// What to speak under the "Read only the bold claims" setting: the
    /// reply's bold claims when it has any, otherwise the whole reply.
    public func spokenText(boldClaimsOnly: Bool) -> String {
        guard boldClaimsOnly, let claims = BoldClaims.spokenText(from: spokenText) else {
            return spokenText
        }
        return claims
    }
}

/// Optional body for `POST /v2/registry/play/{id}`: speak `text` instead of
/// the stored reply. Daemons that predate it ignore the body and read the
/// whole reply.
public struct RegistryPlayRequest: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Body for `POST /v2/registry/partly_heard/{id}`: the part of an
/// auto-read reply the user hasn't heard yet.
public struct RegistryPartlyHeardRequest: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// `POST /v2/registry/partly_heard/{id}` result. `id` names the fresh
/// pending entry; `reason` explains an `ok: false` ("not_pending", "empty").
public struct RegistryPartlyHeardResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let id: String?
    public let reason: String?

    public init(ok: Bool, id: String? = nil, reason: String? = nil) {
        self.ok = ok
        self.id = id
        self.reason = reason
    }
}

public struct RegistryListResponse: Codable, Sendable, Equatable {
    public let pending: [RegistryV2Item]

    public init(pending: [RegistryV2Item]) {
        self.pending = pending
    }
}

public struct RegistryAnnounceRequest: Codable, Sendable, Equatable {
    public let source: String
    public let projectId: String
    public let title: String
    public let ttlS: Int

    enum CodingKeys: String, CodingKey {
        case source
        case projectId = "project_id"
        case title
        case ttlS = "ttl_s"
    }

    public init(source: String, projectId: String, title: String, ttlS: Int = 600) {
        self.source = source
        self.projectId = projectId
        self.title = title
        self.ttlS = ttlS
    }
}

public struct RegistryAnnounceResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let id: String?

    public init(ok: Bool, id: String? = nil) {
        self.ok = ok
        self.id = id
    }
}

/// Computed age in seconds.
extension RegistryV2Item {
    public func ageSeconds(now: Date = Date()) -> Int {
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        return max(0, (nowMs - announcedAtMs) / 1000)
    }

    /// Truncated for the toast / submenu line. Per Sally's spec: ~50 chars.
    public func preview(maxLength: Int = 50) -> String {
        if title.count <= maxLength { return title }
        return String(title.prefix(maxLength)) + "…"
    }
}
