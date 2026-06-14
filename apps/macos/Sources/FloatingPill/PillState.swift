// PillState.swift — the floating pill's finite-state machine, extracted as a
// PURE function so it lives out of the view and is exhaustively unit-testable.
//
// The pill renders exactly one mutually-exclusive *layout* at a time. That
// layout is derived from a handful of orthogonal inputs (player state, hover,
// pin, settings, a pending Claude-output prompt) by `resolvePillLayout(_:)`.
// Keeping the resolution here — not scattered through PillViewModel/PillView
// — means the precedence rules are one readable table and a test can pin every
// cell of it.
import Foundation

/// The mutually-exclusive layout the pill renders. `expanded` and `promptCTA`
/// take the large footprint; the three collapsed layouts share the small chip.
public enum PillLayout: Equatable {
    /// Off-screen entirely.
    case hidden
    /// Always-visible mode, nothing playing: bird + "Myna", no waveform.
    case collapsedIdle
    /// Speak fired but audio hasn't started: bird + "Processing…" + shimmer.
    case processing
    /// Playing or paused: bird + status + waveform.
    case collapsedPlaying
    /// Hover- or pin-expanded mini-player.
    case expanded
    /// New Claude output observed: in-pill "Play?" call-to-action.
    case promptCTA
}

/// The orthogonal inputs that determine the layout. A plain value type so the
/// resolver is trivially testable.
public struct PillInputs: Equatable {
    /// Master "show floating pill" toggle.
    public var enabled: Bool
    /// User's "always visible" setting.
    public var alwaysVisible: Bool
    /// Pre-audio loading flag (drives the "Processing…" affordance).
    public var isLoading: Bool
    /// Player is playing or paused.
    public var isPlaying: Bool
    /// Cursor is over the pill (via NSTrackingArea).
    public var isHovering: Bool
    /// User pinned the pill open.
    public var isPinned: Bool
    /// A pending Claude-output prompt is awaiting the user.
    public var hasPrompt: Bool

    public init(
        enabled: Bool,
        alwaysVisible: Bool,
        isLoading: Bool,
        isPlaying: Bool,
        isHovering: Bool,
        isPinned: Bool,
        hasPrompt: Bool
    ) {
        self.enabled = enabled
        self.alwaysVisible = alwaysVisible
        self.isLoading = isLoading
        self.isPlaying = isPlaying
        self.isHovering = isHovering
        self.isPinned = isPinned
        self.hasPrompt = hasPrompt
    }
}

/// Resolve the single layout from the inputs. Precedence, highest first:
///   1. not enabled                  → hidden
///   2. pending Claude prompt         → promptCTA   (auto-expands the pill)
///   3. pinned OR hovering            → expanded
///   4. loading                       → processing
///   5. playing OR paused             → collapsedPlaying
///   6. always-visible                → collapsedIdle
///   7. otherwise                     → hidden
public func resolvePillLayout(_ i: PillInputs) -> PillLayout {
    guard i.enabled else { return .hidden }
    if i.hasPrompt { return .promptCTA }
    if i.isPinned || i.isHovering { return .expanded }
    if i.isLoading { return .processing }
    if i.isPlaying { return .collapsedPlaying }
    if i.alwaysVisible { return .collapsedIdle }
    return .hidden
}
