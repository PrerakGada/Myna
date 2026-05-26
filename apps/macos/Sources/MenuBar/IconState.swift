// IconState.swift — the 5-state machine the menu bar bird renders
// (S07 thinking indicator). Per Caravaggio's spec
// (04-visual-direction.md § 3):
//
//   idle      — outlined bird, no motion
//   speaking  — filled bird + equalizer bars REPLACING the beak area
//   thinking  — outlined bird + soft halo (3pt outside silhouette,
//                30% opacity peak, 600ms cosine cycle)
//   paused    — outlined bird @ 75% opacity + horizontal bar through body
//   error     — outlined bird + small red dot (#FF453A) at upper-right
//
// Mapped from DaemonStatus.state + AudioPlayer.state per the rules
// in MenuBarController.computeIconState(...).
import Foundation

public enum IconState: String, Sendable, Equatable {
    case idle
    case speaking
    case thinking
    case paused
    case error

    /// True iff the icon should animate (battery / Low Power Mode gate
    /// can multiply this by a hardware-aware flag).
    public var isAnimated: Bool {
        switch self {
        case .speaking, .thinking: return true
        case .idle, .paused, .error: return false
        }
    }
}

/// Combines daemon state + local player state into the single icon
/// state. Pure function so tests don't need to spin up daemon/player.
///
/// Priority:
///   1. Daemon down/unreachable      → .error
///   2. Local player paused          → .paused
///   3. Daemon state speaking/streaming → .speaking
///   4. Local player playing         → .speaking
///   5. Daemon state synthesizing    → .thinking
///   6. Daemon emits "thinking" raw  → .thinking  (Lane B contract)
///   7. Daemon emits "error" raw     → .error
///   8. Otherwise                    → .idle
public enum IconStateMapping {
    public static func compute(
        reachability: MenuBarController.DaemonReachability,
        daemonStateRaw: String?,
        isPlayerPaused: Bool,
        isPlayerPlaying: Bool
    ) -> IconState {
        if reachability == .down { return .error }
        if isPlayerPaused { return .paused }
        if let raw = daemonStateRaw?.lowercased() {
            if raw == "error" { return .error }
            if raw == "speaking" || raw == "streaming" { return .speaking }
            if raw == "thinking" || raw == "synthesizing" { return .thinking }
            if raw == "paused" { return .paused }
        }
        if isPlayerPlaying { return .speaking }
        return .idle
    }
}
