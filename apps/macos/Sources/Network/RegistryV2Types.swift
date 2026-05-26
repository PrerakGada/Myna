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
//   POST /v2/registry/play/{id}  no body; daemon kicks off playback
//      → { ok: bool, reason?: string }
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
    public let announcedAtMs: Int  // unix ms timestamp
    public let ttlS: Int  // suggested time-to-live in seconds

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case projectId = "project_id"
        case title
        case announcedAtMs = "announced_at_ms"
        case ttlS = "ttl_s"
    }

    public init(
        id: String,
        source: String,
        projectId: String,
        title: String,
        announcedAtMs: Int,
        ttlS: Int
    ) {
        self.id = id
        self.source = source
        self.projectId = projectId
        self.title = title
        self.announcedAtMs = announcedAtMs
        self.ttlS = ttlS
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
