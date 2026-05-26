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
public struct BirdIconView: View {
    public let state: IconState
    /// When true, the thinking halo and speaking equalizer hold a static
    /// pose. Wired from PowerMonitor in the menu bar parent view.
    public let suppressAnimation: Bool

    public init(state: IconState, suppressAnimation: Bool = false) {
        self.state = state
        self.suppressAnimation = suppressAnimation
    }

    public var body: some View {
        ZStack {
            haloLayer
            baseBird
            equalizerLayer
            pausedBarLayer
            errorDotLayer
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(state.rawValue)
    }

    // MARK: - layers

    @ViewBuilder
    private var baseBird: some View {
        let opacity: Double = {
            switch state {
            case .paused: return 0.75
            case .idle, .thinking, .error: return 1.0
            case .speaking:
                // In speaking state the bird fills; we render it filled
                // (`bird.fill` when available) at full opacity, but the
                // SF Symbol set on macOS 13 doesn't ship a `bird.fill`
                // variant — using the outline at full opacity reads
                // close enough at menu bar scale. Real spec calls for a
                // custom asset which is a v0.2.1 follow-up.
                return 1.0
            }
        }()
        Image(systemName: state == .speaking ? "bird.fill" : "bird")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .opacity(opacity)
    }

    @ViewBuilder
    private var equalizerLayer: some View {
        if state == .speaking {
            EqualizerBars(suppressAnimation: suppressAnimation)
                // Position roughly where the bird's beak sits in the
                // SF Symbol — right-of-center, slightly above the
                // vertical midline. Numbers tuned for the 22pt menu
                // bar slot.
                .frame(width: 8, height: 8)
                .offset(x: 4, y: -1)
        }
    }

    @ViewBuilder
    private var haloLayer: some View {
        if state == .thinking {
            ThinkingHalo(suppressAnimation: suppressAnimation)
        }
    }

    @ViewBuilder
    private var pausedBarLayer: some View {
        if state == .paused {
            // Horizontal bar through the body at vertical-center.
            GeometryReader { geom in
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: geom.size.width, height: 2)
                    .position(x: geom.size.width / 2, y: geom.size.height / 2)
            }
        }
    }

    @ViewBuilder
    private var errorDotLayer: some View {
        if state == .error {
            GeometryReader { geom in
                Circle()
                    .fill(Color(.sRGB, red: 1.0, green: 69.0 / 255.0, blue: 58.0 / 255.0, opacity: 1.0))  // #FF453A
                    .frame(width: 4, height: 4)
                    .position(x: geom.size.width - 2, y: 2)
            }
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

/// Three-bar equalizer that animates ~2fps with asymmetric phases so it
/// doesn't read as robotic-in-sync. Per spec.
private struct EqualizerBars: View {
    let suppressAnimation: Bool

    /// Phase offset per bar (in 0..<1 of cycle) so the three never sync.
    /// Tuned by eye for a lively-but-not-frantic feel.
    private static let phases: [Double] = [0.0, 0.35, 0.7]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: suppressAnimation)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.5) / 0.5
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<3, id: \.self) { idx in
                    let local = (phase + Self.phases[idx]).truncatingRemainder(dividingBy: 1.0)
                    let height = 0.35 + 0.65 * abs(sin(local * .pi))
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 1.5, height: CGFloat(height) * 7)
                }
            }
        }
    }
}

/// Soft halo behind the bird, 600ms cosine cycle, peak ~30% opacity.
/// Suspends when PowerMonitor flags low power.
private struct ThinkingHalo: View {
    let suppressAnimation: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: suppressAnimation)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            // 600ms cycle = 1.667Hz; cosine peak at top of cycle.
            let cyclePos = (now.truncatingRemainder(dividingBy: 0.6)) / 0.6  // 0..<1
            let opacity = 0.3 * (1 - cos(cyclePos * 2 * .pi)) / 2  // 0..0.3..0
            Circle()
                .fill(Color.primary)
                .opacity(opacity)
                .blur(radius: 3)
        }
    }
}
