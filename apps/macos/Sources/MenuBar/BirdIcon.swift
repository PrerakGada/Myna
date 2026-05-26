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
/// The new implementation is static: one SF Symbol per state, no
/// `TimelineView`, no compositing layers. The visual richness (halo,
/// equalizer bars, etc.) is restored later via the v0.2.1 UI revamp using
/// `.symbolEffect()` (macOS 14+ GPU-accelerated animation) or a pre-rendered
/// custom asset bundle.
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
        Image(systemName: symbolName)
            .renderingMode(.template)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(state.rawValue)
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
