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
///   2. Daemon reachable but engine down (engine_up == false) → .error
///   3. Local player paused          → .paused
///   4. Daemon state speaking/streaming → .speaking
///   5. Local player playing         → .speaking
///   6. Daemon state synthesizing    → .thinking
///   7. Daemon emits "thinking" raw  → .thinking  (Lane B contract)
///   8. Daemon emits "error" raw     → .error
///   9. Local player loading (pre-audio) → .thinking
///  10. Otherwise                    → .idle
///
/// "Local player loading" is the pre-audio prelude flag the dispatcher
/// flips the moment a speak request fires (before the daemon's first
/// chunk lands). The 250ms idle-polling cadence means the daemon's own
/// "synthesizing" status arrives 100-200ms late — pre-empting with the
/// local signal closes that gap so the icon transitions to thinking
/// within ~50ms of the user's hotkey.
public enum IconStateMapping {
    public static func compute(
        reachability: MenuBarController.DaemonReachability,
        daemonStateRaw: String?,
        isPlayerPaused: Bool,
        isPlayerPlaying: Bool,
        isEngineUp: Bool? = nil,
        isPlayerLoading: Bool = false
    ) -> IconState {
        if reachability == .down { return .error }
        // A reachable daemon can still report its engine is down — surface
        // that as an error so the user doesn't see "idle" while playback
        // would actually fail. When `isEngineUp` is nil (caller didn't
        // supply it), preserve the legacy behavior of trusting reachability.
        if isEngineUp == false { return .error }
        if isPlayerPaused { return .paused }
        if let raw = daemonStateRaw?.lowercased() {
            if raw == "error" { return .error }
            if raw == "speaking" || raw == "streaming" { return .speaking }
            if raw == "thinking" || raw == "synthesizing" { return .thinking }
            if raw == "paused" { return .paused }
        }
        if isPlayerPlaying { return .speaking }
        // Pre-audio loading takes precedence over idle so the user sees
        // an immediate "thinking" cue while the daemon spools up.
        if isPlayerLoading { return .thinking }
        return .idle
    }
}
