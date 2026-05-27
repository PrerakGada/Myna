// MenuBarViewModel.swift — pure-data structures that describe the
// state-driven popover (S06) without coupling to SwiftUI. Tests assert
// against these structs without launching a real `MenuBarView`.
//
// Per Sally's spec (03-ux-direction.md § 1) the popover reads
// top-to-bottom:
//   1. Now Reading header        (collapses to "No audio playing" when idle)
//   2. Transport block           (hides entirely when idle)
//   3. Voice ▸ submenu
//   4. Speed ▸ submenu
//   5. Recent ▸ submenu          (last 5)
//   6. Claude Code ▸ submenu     (only when registry non-empty)
//   7. Settings…, Restart Daemon, Quit
import Foundation

/// Action identifier for a transport row in PopoverModel.
public enum TransportAction: String, Sendable, Equatable {
    case pause
    case stop
    case skipForward
    case skipBack
}

public struct PopoverModel: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case idle
        /// Pre-audio "we asked the daemon, haven't heard back yet" state.
        /// Owns an optional preview title (sourced from the dispatcher's
        /// recent-title computation) so the hero can show what's being
        /// requested without making it look like audio is already playing.
        case loading(title: String?)
        case playing(NowReading)
        case paused(NowReading)
        case error(message: String)

        public var isIdle: Bool {
            guard case .idle = self else { return false }
            return true
        }
        public var nowReading: NowReading? {
            switch self {
            case .playing(let nr), .paused(let nr): return nr
            case .idle, .loading, .error: return nil
            }
        }
    }

    public struct NowReading: Sendable, Equatable {
        public let title: String
        public let voice: String
        public let speed: Double
        public let positionSeconds: TimeInterval
        public let durationSeconds: TimeInterval

        public init(
            title: String, voice: String, speed: Double, positionSeconds: TimeInterval, durationSeconds: TimeInterval
        ) {
            self.title = title
            self.voice = voice
            self.speed = speed
            self.positionSeconds = positionSeconds
            self.durationSeconds = durationSeconds
        }

        public var truncatedTitle: String {
            let max = 38
            if title.count <= max { return title }
            return String(title.prefix(max)) + "…"
        }

        public var formattedMetadata: String {
            "\(voice) · \(String(format: "%.1fx", speed)) · \(formatTime(positionSeconds)) / \(formatTime(durationSeconds))"
        }

        private func formatTime(_ seconds: TimeInterval) -> String {
            let total = Int(max(0, seconds))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    public struct TransportRow: Sendable, Equatable, Identifiable {
        public let id: TransportAction
        public let title: String
        /// Display string for the hotkey trailing label, e.g. "⌘⌥⇧S".
        /// Nil when no shortcut is bound.
        public let hotkeyLabel: String?
        /// Whether the row is enabled. Idle disables Pause/Stop.
        public let isEnabled: Bool

        public init(id: TransportAction, title: String, hotkeyLabel: String?, isEnabled: Bool) {
            self.id = id
            self.title = title
            self.hotkeyLabel = hotkeyLabel
            self.isEnabled = isEnabled
        }
    }

    public let status: Status
    public let transport: [TransportRow]
    public let recents: [RecentItem]
    public let ccItems: [RegistryV2Item]
    public let showClaudeCodeSubmenu: Bool

    public init(
        status: Status,
        transport: [TransportRow],
        recents: [RecentItem],
        ccItems: [RegistryV2Item]
    ) {
        self.status = status
        self.transport = transport
        self.recents = recents
        self.ccItems = ccItems
        self.showClaudeCodeSubmenu = !ccItems.isEmpty
    }
}

public enum PopoverModelBuilder {
    // Pure transformation: state in, popover model out.
    // Used by MenuBarController.popoverModel() and unit tests.
    // swiftlint:disable:next function_parameter_count
    public static func build(
        playerState: AudioPlayer.State,
        nowReading: PopoverModel.NowReading?,
        recents: [RecentItem],
        ccItems: [RegistryV2Item],
        reachability: MenuBarController.DaemonReachability,
        hotkeyLabelFor: (HotkeyAction) -> String?,
        isPlayerLoading: Bool = false,
        loadingTitle: String? = nil
    ) -> PopoverModel {
        let status: PopoverModel.Status
        switch (reachability, playerState) {
        case (.down, _):
            status = .error(message: "Daemon unreachable")
        case (_, .paused):
            status = .paused(
                nowReading
                    ?? PopoverModel.NowReading(
                        title: "Paused",
                        voice: "—",
                        speed: 1.0,
                        positionSeconds: 0,
                        durationSeconds: 0
                    ))
        case (_, .playing):
            status = .playing(
                nowReading
                    ?? PopoverModel.NowReading(
                        title: "Now reading",
                        voice: "—",
                        speed: 1.0,
                        positionSeconds: 0,
                        durationSeconds: 0
                    ))
        case (_, .idle):
            // The loading flag only kicks in while the player is idle —
            // once audio starts playing the .playing branch above already
            // owns the hero. This keeps the status enum total and avoids
            // a "loading + paused" ambiguity that doesn't exist in practice.
            status = isPlayerLoading ? .loading(title: loadingTitle) : .idle
        }
        let isPlaying = playerState == .playing
        let isPaused = playerState == .paused
        let isActive = isPlaying || isPaused
        let rows: [PopoverModel.TransportRow] = [
            PopoverModel.TransportRow(
                id: .pause,
                title: isPaused ? "Resume" : "Pause",
                hotkeyLabel: hotkeyLabelFor(.pauseResume),
                isEnabled: isActive
            ),
            PopoverModel.TransportRow(
                id: .stop,
                title: "Stop",
                hotkeyLabel: hotkeyLabelFor(.stop),
                isEnabled: isActive
            ),
            PopoverModel.TransportRow(
                id: .skipForward,
                title: "Skip ahead 15s",
                hotkeyLabel: nil,
                isEnabled: isActive
            ),
            PopoverModel.TransportRow(
                id: .skipBack,
                title: "Skip back 15s",
                hotkeyLabel: nil,
                isEnabled: isActive
            ),
        ]
        return PopoverModel(
            status: status,
            transport: rows,
            recents: recents,
            ccItems: ccItems
        )
    }
}
