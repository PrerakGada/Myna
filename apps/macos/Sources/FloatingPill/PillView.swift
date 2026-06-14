// PillView.swift — the SwiftUI floating-pill UI.
//
// One root that switches on `viewModel.layout` (the FSM from PillState.swift):
//   • collapsedIdle      → bird badge + "Myna"
//   • processing         → bird badge + "Processing…" + mini spinner
//   • collapsedPlaying   → bird badge + status + Core-Animation waveform
//   • expanded           → mini-player: headline, voice chip, waveform, transport
//   • promptCTA          → (Step 8) in-pill Claude-output call-to-action
//
// matchedGeometryEffect on bird / status / waveform morphs the shared elements
// between collapsed and expanded; the window-frame animation (PillController)
// grows the panel upward in lock-step.
//
// CRITICAL: the waveform MUST NOT use TimelineView. A prior TimelineView
// implementation pegged a CPU core at 99.5%. We drive it with a
// CAReplicatorLayer + CABasicAnimation on the render server instead, so
// main-thread CPU stays ~0% while the pill is visible.
import AppKit
import SwiftUI

// MARK: - design tokens

private enum PillStyle {
    // sizes
    static let collapsedHeight: CGFloat = 36
    static let collapsedHPadding: CGFloat = 12
    static let expandedWidth: CGFloat = 340
    static let badgeCollapsed: CGFloat = 24
    static let badgeExpanded: CGFloat = 30

    // radii
    static let collapsedRadius: CGFloat = 18      // half of collapsed height
    static let expandedRadius: CGFloat = 20

    // typography
    static let statusFont = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let headlineFont = Font.system(size: 13, weight: .medium, design: .rounded)
    static let chipFont = Font.system(size: 10, weight: .semibold, design: .rounded)

    // motion
    static let morph: Animation = .spring(response: 0.30, dampingFraction: 0.82)

    // waveform
    static let waveformDotSize: CGFloat = 3.5
    static let waveformDotSpacing: CGFloat = 4
    static let waveformDotCount: Int = 3
    static var dotsWidth: CGFloat {
        let n = CGFloat(waveformDotCount)
        return n * waveformDotSize + (n - 1) * waveformDotSpacing
    }
}

// MARK: - root

public struct PillView: View {
    @ObservedObject var viewModel: PillViewModel
    @Namespace private var ns

    public init(viewModel: PillViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        content
            .animation(PillStyle.morph, value: viewModel.layout)
            // Hover is driven by PillTrackingView (NSTrackingArea) via
            // PillController, not SwiftUI .onHover. Tap-to-pin arrives via
            // FloatingPillWindow.onBackgroundTap. We still expose an
            // accessibility action so VoiceOver can reach togglePin().
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAction { viewModel.togglePin() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.layout {
        case .hidden:
            // The window is ordered out in this state; render nothing.
            Color.clear.frame(width: 1, height: 1)
        case .collapsedIdle:
            collapsedChip(status: "Myna", trailing: .none)
        case .processing:
            collapsedChip(status: "Processing\u{2026}", trailing: .spinner)
        case .collapsedPlaying:
            collapsedChip(
                status: viewModel.isPaused ? "Paused" : "Speaking",
                trailing: .waveform(playing: !viewModel.isPaused)
            )
        case .expanded, .promptCTA:
            // promptCTA falls back to the expanded mini-player until Step 8.
            expanded
        }
    }

    private var accessibilityLabel: String {
        if viewModel.isPaused { return "Myna paused" }
        if viewModel.isSpeaking { return "Myna speaking" }
        if viewModel.isLoading { return "Myna processing" }
        return "Myna"
    }

    // MARK: - collapsed

    private enum Trailing: Equatable {
        case none
        case spinner
        case waveform(playing: Bool)
    }

    private func collapsedChip(status: String, trailing: Trailing) -> some View {
        HStack(spacing: 8) {
            birdBadge(diameter: PillStyle.badgeCollapsed)
                .matchedGeometryEffect(id: "bird", in: ns)

            Text(status)
                .font(PillStyle.statusFont)
                .foregroundStyle(.primary)
                .fixedSize()
                .matchedGeometryEffect(id: "status", in: ns)

            trailingIndicator(trailing, height: 12)
                .matchedGeometryEffect(id: "waveform", in: ns)
        }
        .padding(.horizontal, PillStyle.collapsedHPadding)
        .frame(height: PillStyle.collapsedHeight)
        .background(pillBackground(cornerRadius: PillStyle.collapsedRadius))
        .overlay(
            Capsule().stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func trailingIndicator(_ trailing: Trailing, height: CGFloat) -> some View {
        switch trailing {
        case .none:
            Color.clear.frame(width: 0, height: height)
        case .spinner:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(.secondary)
                .frame(width: PillStyle.dotsWidth, height: height)
        case .waveform(let playing):
            WaveformDots(isPlaying: playing)
                .frame(width: PillStyle.dotsWidth, height: height)
        }
    }

    // MARK: - expanded mini-player

    private var expandedHeadline: String {
        if let text = viewModel.previewText, !text.isEmpty { return text }
        if viewModel.isLoading && !viewModel.isSpeaking { return "Processing\u{2026}" }
        if viewModel.isPaused { return "Paused" }
        if viewModel.isSpeaking { return "Speaking\u{2026}" }
        return "Myna"
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1 — badge + headline + close
            HStack(spacing: 10) {
                birdBadge(diameter: PillStyle.badgeExpanded)
                    .matchedGeometryEffect(id: "bird", in: ns)

                VStack(alignment: .leading, spacing: 2) {
                    Text(expandedHeadline)
                        .font(PillStyle.headlineFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .matchedGeometryEffect(id: "status", in: ns)
                    HStack(spacing: 6) {
                        voiceChip
                        if viewModel.isLoading && !viewModel.isSpeaking {
                            trailingIndicator(.spinner, height: 10)
                                .matchedGeometryEffect(id: "waveform", in: ns)
                        } else if viewModel.isSpeaking {
                            trailingIndicator(.waveform(playing: !viewModel.isPaused), height: 10)
                                .matchedGeometryEffect(id: "waveform", in: ns)
                        } else {
                            Color.clear.frame(width: 0, height: 10)
                                .matchedGeometryEffect(id: "waveform", in: ns)
                        }
                    }
                }

                Spacer(minLength: 8)

                closeButton
            }

            // Row 2 — transport (only when there's a session to control)
            if viewModel.isSpeaking || viewModel.isLoading {
                transportRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: PillStyle.expandedWidth, alignment: .leading)
        .background(pillBackground(cornerRadius: PillStyle.expandedRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PillStyle.expandedRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var voiceChip: some View {
        Text(viewModel.voiceLabel)
            .font(PillStyle.chipFont)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.09)))
    }

    private var transportRow: some View {
        HStack(spacing: 14) {
            transportButton(
                system: viewModel.isPaused ? "play.fill" : "pause.fill",
                size: 15,
                help: viewModel.isPaused ? "Resume" : "Pause"
            ) { viewModel.togglePlayPause() }
            .disabled(!viewModel.isSpeaking)

            transportButton(system: "forward.fill", size: 12, help: "Skip ahead") {
                viewModel.skipToNextChunk()
            }
            .disabled(!viewModel.isSpeaking)

            transportButton(system: "stop.fill", size: 12, help: "Stop") {
                viewModel.stop()
            }
            .disabled(!viewModel.isSpeaking)

            Spacer(minLength: 0)
        }
        .padding(.leading, PillStyle.badgeExpanded + 10) // align under the headline
    }

    private func transportButton(
        system: String, size: CGFloat, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PillIconButtonStyle())
        .help(help)
        // Swallow the parent tap-to-pin so transport taps don't toggle pin.
        .simultaneousGesture(TapGesture().onEnded {})
    }

    private var closeButton: some View {
        let collapsing = viewModel.isAlwaysVisible && !viewModel.isSpeaking && !viewModel.isLoading
        return Button { viewModel.dismiss() } label: {
            Image(systemName: collapsing ? "chevron.down" : "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(PillIconButtonStyle())
        .help(collapsing ? "Collapse" : "Hide")
        .simultaneousGesture(TapGesture().onEnded {})
    }

    // MARK: - bird badge

    private func birdBadge(diameter: CGFloat) -> some View {
        Image(systemName: "bird.fill")
            .font(.system(size: diameter * 0.58, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 1)
    }

    // MARK: - background

    @ViewBuilder
    private func pillBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.28))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 6)
    }
}

// MARK: - icon button style

private struct PillIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.0))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(isEnabledOpacity(configuration))
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func isEnabledOpacity(_ configuration: Configuration) -> Double { 1.0 }
}

// MARK: - waveform (Core Animation, NOT TimelineView)

/// Three dots that scale in a staggered loop via CABasicAnimation on a
/// CAReplicatorLayer — Core Animation runs it on the render server, so
/// main-thread CPU stays ~0%. (TimelineView here once pegged a core at 99.5%.)
private struct WaveformDots: NSViewRepresentable {
    let isPlaying: Bool

    func makeNSView(context: Context) -> WaveformDotsView {
        let view = WaveformDotsView()
        view.isPlaying = isPlaying
        return view
    }

    func updateNSView(_ nsView: WaveformDotsView, context: Context) {
        nsView.isPlaying = isPlaying
    }
}

private final class WaveformDotsView: NSView {
    private let replicator = CAReplicatorLayer()
    private let dot = CALayer()
    private static let dotCount = PillStyle.waveformDotCount
    private static let dotSize = PillStyle.waveformDotSize
    private static let dotSpacing = PillStyle.waveformDotSpacing
    private static let cycleDuration: CFTimeInterval = 1.2

    var isPlaying: Bool = true {
        didSet { syncAnimation() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        dot.backgroundColor = NSColor.white.cgColor
        dot.frame = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        dot.cornerRadius = Self.dotSize / 2
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        replicator.instanceCount = Self.dotCount
        replicator.instanceTransform = CATransform3DMakeTranslation(Self.dotSize + Self.dotSpacing, 0, 0)
        replicator.instanceDelay = Self.cycleDuration / Double(Self.dotCount * 2)
        replicator.addSublayer(dot)
        layer?.addSublayer(replicator)
    }

    override func layout() {
        super.layout()
        let centreY = bounds.midY
        let totalWidth = CGFloat(Self.dotCount) * Self.dotSize
            + CGFloat(Self.dotCount - 1) * Self.dotSpacing
        let originX = (bounds.width - totalWidth) / 2
        replicator.frame = bounds
        dot.position = CGPoint(x: originX + Self.dotSize / 2, y: centreY)
        syncAnimation()
    }

    private func syncAnimation() {
        dot.removeAnimation(forKey: "pulse")
        guard isPlaying else {
            dot.transform = CATransform3DMakeScale(0.8, 0.8, 1)
            return
        }
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.5
        anim.toValue = 1.15
        anim.duration = Self.cycleDuration / 2
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(anim, forKey: "pulse")
    }

    override var isFlipped: Bool { false }
}

// MARK: - previews

#if DEBUG
// swiftlint:disable:next type_name
struct PillView_PreviewModel {
    @MainActor
    static func make(
        isSpeaking: Bool,
        isExpanded: Bool,
        withText: Bool = false,
        paused: Bool = false,
        alwaysVisible: Bool = false,
        loading: Bool = false
    ) -> PillViewModel {
        let player = AudioPlayer()
        let suite = UserDefaults(suiteName: "preview-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        let settings = SettingsViewModel(store: store)
        settings.voice = "af_heart"
        let bridge = PillBridge()
        if withText {
            bridge.publish(
                currentText: "Once upon a time, there was a small bird named Myna who liked to read aloud.",
                voice: "af_heart"
            )
        }
        let vm = PillViewModel(player: player, settings: settings, bridge: bridge)
        vm._previewForceState(
            isSpeaking: isSpeaking,
            isExpanded: isExpanded,
            paused: paused,
            alwaysVisible: alwaysVisible,
            loading: loading
        )
        return vm
    }
}

#Preview("Collapsed — speaking") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: true, isExpanded: false))
        .padding(40).background(Color.gray.opacity(0.2))
}

#Preview("Collapsed — processing") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: false, isExpanded: false, loading: true))
        .padding(40).background(Color.gray.opacity(0.2))
}

#Preview("Expanded — with text") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: true, isExpanded: true, withText: true))
        .padding(40).background(Color.gray.opacity(0.2))
}

#Preview("Collapsed — idle (always visible)") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: false, isExpanded: false, alwaysVisible: true))
        .padding(40).background(Color.gray.opacity(0.2))
}
#endif
