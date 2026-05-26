// WhatsNewState.swift — persistence for the What's New dialog (S10).
//
// File: ~/Library/Application Support/Myna/state.json
// Schema:
//   {
//     "last_seen_version": "0.1.0",
//     "first_run_complete": true,
//     "last_updated_at_ms": 0
//   }
//
// Safe defaults on missing file (first run): last_seen_version = "0.0.0",
// first_run_complete = false. Per S10 AC #1.
import Foundation

public struct WhatsNewState: Codable, Sendable, Equatable {
    public var lastSeenVersion: String
    public var firstRunComplete: Bool
    public var lastUpdatedAtMs: Int

    enum CodingKeys: String, CodingKey {
        case lastSeenVersion = "last_seen_version"
        case firstRunComplete = "first_run_complete"
        case lastUpdatedAtMs = "last_updated_at_ms"
    }

    public init(lastSeenVersion: String, firstRunComplete: Bool, lastUpdatedAtMs: Int) {
        self.lastSeenVersion = lastSeenVersion
        self.firstRunComplete = firstRunComplete
        self.lastUpdatedAtMs = lastUpdatedAtMs
    }

    /// Defaults for a fresh install where the file doesn't exist yet.
    public static var defaults: WhatsNewState {
        WhatsNewState(
            lastSeenVersion: "0.0.0",
            firstRunComplete: false,
            lastUpdatedAtMs: 0
        )
    }
}

/// Disk-backed state store. Reads return `.defaults` if the file is
/// missing or unreadable. Writes are best-effort: a write failure logs
/// but never propagates (this state file isn't load-bearing — the worst
/// case is the dialog shows again next launch).
public final class WhatsNewStateStore: @unchecked Sendable {
    public static let shared = WhatsNewStateStore()

    private let fileURL: URL
    private let lock = NSLock()

    /// Default URL lives under `~/Library/Application Support/Myna/`.
    /// Tests inject a tmp path.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL =
                appSupport
                .appendingPathComponent("Myna", isDirectory: true)
                .appendingPathComponent("state.json")
        }
    }

    public var url: URL { fileURL }

    public func load() -> WhatsNewState {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .defaults
        }
        do {
            return try JSONDecoder().decode(WhatsNewState.self, from: data)
        } catch {
            // Malformed file is treated as missing. We don't overwrite it
            // here — that's the caller's choice on next save.
            return .defaults
        }
    }

    @discardableResult
    public func save(_ state: WhatsNewState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
