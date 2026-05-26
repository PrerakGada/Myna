// RecentItem.swift — the "Recent" submenu (S06) shows the last 5 items
// Myna read. Persisted to UserDefaults so it survives relaunch.
//
// Per Sally's spec (03-ux-direction.md § 1): each row shows
// `Bella · 2 min ago · "Designing Data-Intensive…"`. Click → re-reads
// from start (we ship the re-read hook in v0.2.1; for v0.2 the click
// emits a `RecentItemSelected` notification the dispatcher can wire to
// future "re-speak the same text" support).
import Foundation

public struct RecentItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let voice: String
    public let createdAtMs: Int

    public init(id: String = UUID().uuidString, title: String, voice: String, createdAtMs: Int) {
        self.id = id
        self.title = title
        self.voice = voice
        self.createdAtMs = createdAtMs
    }

    /// Truncate the title for menu display. Per Sally's spec: 38 chars
    /// + ellipsis.
    public func truncatedTitle(maxLength: Int = 38) -> String {
        if title.count <= maxLength { return title }
        return String(title.prefix(maxLength)) + "…"
    }

    /// Relative age string ("just now", "2 min ago", "1 h ago"). The
    /// menu pulls a fresh string on every popover open so users see
    /// monotonically increasing ages.
    public func ageString(nowMs: Int = Self.currentTimeMs()) -> String {
        let deltaSec = max(0, (nowMs - createdAtMs) / 1000)
        if deltaSec < 30 { return "just now" }
        if deltaSec < 60 { return "\(deltaSec) s ago" }
        if deltaSec < 3_600 { return "\(deltaSec / 60) min ago" }
        if deltaSec < 86_400 { return "\(deltaSec / 3_600) h ago" }
        return "\(deltaSec / 86_400) d ago"
    }

    /// Display string used by the popover. Format:
    /// `voice · ageStr · "title…"` (e.g. `Bella · 2 min ago · "Designing…"`).
    public func displayLine(nowMs: Int = Self.currentTimeMs()) -> String {
        "\(voice) · \(ageString(nowMs: nowMs)) · \"\(truncatedTitle())\""
    }

    public static func currentTimeMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}

/// Persistent ring buffer of the last 5 reads.
public final class RecentItemsStore: @unchecked Sendable {
    public static let shared = RecentItemsStore()

    public static let maxCount = 5
    private static let storageKey = "dev.myna.app.recentItems"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current items in newest-first order.
    public func load() -> [RecentItem] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([RecentItem].self, from: data)) ?? []
    }

    /// Prepend a new item; trim to maxCount.
    public func add(_ item: RecentItem) {
        lock.lock()
        defer { lock.unlock() }
        var current =
            (try? JSONDecoder().decode([RecentItem].self, from: defaults.data(forKey: Self.storageKey) ?? Data())) ?? []
        current.insert(item, at: 0)
        if current.count > Self.maxCount {
            current = Array(current.prefix(Self.maxCount))
        }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }
}
