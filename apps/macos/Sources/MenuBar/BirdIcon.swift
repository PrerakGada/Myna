// BirdIcon.swift — the menu bar bird. v0.2 turns this into a state-driven
// SwiftUI view per Caravaggio's spec (04-visual-direction.md § 3). Five
// states: idle, speaking, thinking, paused, error.
//
// Construction:
//   - Base bird = SF Symbol "bird" (template-rendered, follows system
//     monochrome). The single shared base means dark/light/accent
//     adaptation comes for free.
//   - Speaking: 3-bar equalizer overlay positioned in the beak area
//     (NOT next to the bird — fused into the silhouette per spec)
//   - Thinking: soft halo behind the bird, 600ms cosine pulse, ~30%
//     peak opacity. Halo respects PowerMonitor.shouldSuppressAnimation.
//   - Paused: bird @ 75% opacity + horizontal bar at vertical-center
//   - Error: small red corner dot at upper-right (#FF453A macOS red)
//
// Implementation note on rendering: MenuBarExtra's `label:` slot in
// SwiftUI accepts a view; we render BirdIcon directly there. The system
// scales it to fit the menu bar (~18-22pt on standard macOS bars).
//
// Legacy: `BirdIcon.image` and `BirdIcon.systemName` static accessors
// stay for any callers that want the bare SF Symbol Image (test scaffolds,
// the "Myna initialising…" fallback view). New callers should construct
// `BirdIconView(state: ...)`.
import SwiftUI

public enum BirdIcon {
    /// Static SF Symbol Image — kept for back-compat with v0.1 call sites.
    /// New code should prefer `BirdIconView(state:)`.
    public static var image: Image {
        Image(systemName: "bird")
    }

    public static var systemName: String { "bird" }
}

/// SwiftUI view that renders the bird in one of the 5 states.
///
/// **v0.2.1 hotfix:** the original implementation used `TimelineView` at 20fps
/// (thinking halo) and 4fps (speaking equalizer). Combined with
/// `MenuBarController` re-publishing on every 250ms poll, the menu bar label
/// rebuilt continuously — `NSStatusBarButton setImage:` → CoreUI SF Symbol
/// resolution → 99% main thread CPU even at idle.
///
/// The implementation is static: one SF Symbol per state, no
/// `TimelineView`, no compositing layers. The thinking state adds a
/// `.symbolEffect(.pulse, options: .repeating)` on macOS 14+ — this is
/// GPU-driven (Core Animation render server, not the main thread) so it
/// cannot regress the 99.5% CPU bug. The pulse only fires while the
/// state actually is `.thinking`; idle / speaking / paused / error stay
/// fully static.
public struct BirdIconView: View {
    public let state: IconState
    /// Kept for API stability — currently unused. The previous TimelineView
    /// animations have been removed; future custom-asset animation will gate
    /// on this flag again.
    public let suppressAnimation: Bool

    public init(state: IconState, suppressAnimation: Bool = false) {
        self.state = state
        self.suppressAnimation = suppressAnimation
    }

    public var body: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: symbolName)
                .renderingMode(.template)
                // `.symbolEffect(.pulse, ...)` is GPU-driven on macOS 14+
                // — it ships through Core Animation's render server, not
                // the main thread, so it doesn't tip the menu bar back
                // into the v0.2.1 99.5% CPU trap that killed TimelineView.
                // We only apply it to the "thinking" state so the icon's
                // pre-audio loading affordance is *visibly* distinct from
                // idle (a static ellipsis is easy to mistake for "nothing
                // happening" the first time a user hits the hotkey).
                .symbolEffectIfPulsing(isPulsing: state == .thinking)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(state.rawValue)
        } else {
            Image(systemName: symbolName)
                .renderingMode(.template)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(state.rawValue)
        }
    }

    // MARK: - state → symbol

    /// One SF Symbol per state. All symbols below ship on macOS 13+ so the
    /// CUICatalog lookup hits cache reliably.
    private var symbolName: String {
        switch state {
        case .idle:     return "bird"           // outlined bird
        case .speaking: return "bird.fill"      // filled bird = "active"
        case .thinking: return "ellipsis.circle"
        case .paused:   return "pause.circle.fill"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Myna idle"
        case .speaking: return "Myna speaking"
        case .thinking: return "Myna thinking"
        case .paused: return "Myna paused"
        case .error: return "Myna error"
        }
    }
}

@available(macOS 14.0, *)
private extension View {
    /// Apply the `.pulse` symbol effect when `isPulsing` is true; no-op
    /// otherwise. Wrapping the conditional in a view-modifier keeps the
    /// caller free of `if/else` ladders and ensures both branches return
    /// the same opaque type — SwiftUI's "modify the modifier list, not
    /// the view tree" idiom for state-dependent effects.
    @ViewBuilder
    func symbolEffectIfPulsing(isPulsing: Bool) -> some View {
        if isPulsing {
            // `.repeating` is the macOS 14-compatible option (the more
            // granular `.repeat(.periodic(delay:))` form is macOS 15+).
            // The pulse cycle is ~1.5s which is plenty calm for a status
            // icon — no need for finer-grained control.
            self.symbolEffect(.pulse, options: .repeating)
        } else {
            self
        }
    }
}
