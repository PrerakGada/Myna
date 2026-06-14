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
    static let expandedWidth: CGFloat = 340
    static let badgeExpanded: CGFloat = 30

    // radii
    static let expandedRadius: CGFloat = 20

    // typography
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
    // Scrubber drag state: while the user drags, the slider follows their
    // pointer (scrubValue) instead of the live player position.
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

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
            // Minimal footprint: a thin bar, no icon/text, so it never
            // blocks the apps behind it. Hover expands to the full pill.
            CollapsedBar(kind: .idle)
        case .processing:
            CollapsedBar(kind: .processing)
        case .collapsedPlaying:
            CollapsedBar(kind: viewModel.isPaused ? .paused : .playing)
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
            // In-pill Claude-output prompt (auto-expands; never a top-right toast)
            if let prompt = viewModel.pendingPrompt {
                promptBanner(prompt)
            }
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

            // Scrubber + transport (only with a live session to control)
            if viewModel.isSpeaking {
                scrubberRow
                controlsRow
            }

            // Recent reads — pinned only (keeps the hover footprint small).
            if viewModel.isPinned && !viewModel.recents.isEmpty {
                transcriptList
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

    private var scrubberRow: some View {
        HStack(spacing: 8) {
            Text(timeLabel(viewModel.position))
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : viewModel.position },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(viewModel.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubValue = viewModel.position
                    } else {
                        viewModel.seek(toSeconds: scrubValue)
                        isScrubbing = false
                    }
                }
            )
            .controlSize(.mini)
            .tint(.accentColor)
            // Don't let a slider interaction bubble up to tap-to-pin.
            .simultaneousGesture(TapGesture().onEnded {})
            Text(timeLabel(viewModel.duration))
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            transportButton(system: "gobackward.10", size: 13, help: "Back 10s") {
                viewModel.seekBy(-10)
            }
            transportButton(
                system: viewModel.isPaused ? "play.fill" : "pause.fill",
                size: 16,
                help: viewModel.isPaused ? "Resume" : "Pause"
            ) { viewModel.togglePlayPause() }
            transportButton(system: "goforward.10", size: 13, help: "Forward 10s") {
                viewModel.seekBy(10)
            }
            transportButton(system: "stop.fill", size: 12, help: "Stop") {
                viewModel.stop()
            }
            Spacer(minLength: 0)
            speedButton
        }
    }

    private var speedButton: some View {
        Button { viewModel.cycleSpeed() } label: {
            Text(viewModel.speedLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 30, minHeight: 22)
                .padding(.horizontal, 6)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .simultaneousGesture(TapGesture().onEnded {})
    }

    private func timeLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RECENT")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .kerning(0.6)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 3)
            ForEach(viewModel.recents) { item in
                PillRecentRow(item: item) { viewModel.replay(item) }
            }
        }
        // Hairline separates the transport block above from the recents.
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func promptBanner(_ item: RegistryV2Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                Text("New output ready")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            Text(item.preview(maxLength: 80))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { viewModel.playPrompt() } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {})

                Button { viewModel.dismissPrompt() } label: {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {})

                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // `glassEffect` only EXISTS in the macOS 26 SDK (Xcode 26 / Swift 6.2+).
        // A runtime `#available(macOS 26.0, *)` check is not enough: on an older
        // SDK the symbol is absent and the file won't compile at all. Release CI
        // builds on Xcode 16 / macOS 15 SDK, so the glass path must be excluded
        // at COMPILE time there — hence the `#if compiler(>=6.2)` gate. On a
        // macOS 26 toolchain we still fall back to the material below at runtime
        // on pre-26 systems.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Liquid Glass: a tinted regular glass so the dark chrome reads
            // over bright desktops while still refracting what's behind it.
            shape
                .fill(.clear)
                .glassEffect(.regular.tint(Color.black.opacity(0.18)), in: shape)
                .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 6)
        } else {
            pillMaterialBackground(shape)
        }
        #else
        pillMaterialBackground(shape)
        #endif
    }

    /// Pre-Liquid-Glass background: stacked ultra-thin material + dark wash.
    /// Used on macOS < 26 at runtime, and as the sole path when built against
    /// an SDK that predates `glassEffect`.
    @ViewBuilder
    private func pillMaterialBackground(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.28))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 6)
    }
}

// MARK: - collapsed bar

/// The collapsed pill is a thin, contentless bar — no bird, no text — so it
/// stays out of the way of whatever's behind it. State reads purely from tint
/// (a frosted neutral when idle; accent while working/playing, with a soft
/// pulse) and hovering expands it to the full mini-player. PillController
/// shrinks the panel to this bar's footprint, so the hover/click target is
/// just this strip at the bottom-centre of the screen.
private struct CollapsedBar: View {
    enum Kind: Equatable { case idle, processing, playing, paused }
    let kind: Kind
    @State private var pulse = false

    // Visible bar.
    private static let barWidth: CGFloat = 64
    private static let barHeight: CGFloat = 6
    // Transparent padding around the bar — a comfortably larger hover/click
    // target than the 6pt-tall bar itself.
    private static let hitWidth: CGFloat = 84
    private static let hitHeight: CGFloat = 18

    /// Accent wash opacity over the frosted base. Idle stays pure frost.
    private var tintOpacity: Double {
        switch kind {
        case .idle: return 0.0
        case .processing, .playing: return 0.85
        case .paused: return 0.4
        }
    }

    private var animates: Bool { kind == .processing || kind == .playing }

    var body: some View {
        let cap = Capsule(style: .continuous)
        return cap
            .fill(.ultraThinMaterial)
            .overlay(cap.fill(Color.accentColor.opacity(tintOpacity)))
            .overlay(cap.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .frame(width: Self.barWidth, height: Self.barHeight)
            .opacity(animates && pulse ? 0.5 : 1.0)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .frame(width: Self.hitWidth, height: Self.hitHeight)
            .contentShape(Rectangle())
            .onAppear {
                guard animates else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            // Remount on kind change so the pulse restarts (or stops) cleanly
            // across idle↔processing↔playing with no stale animation lingering.
            .id(kind)
    }
}

// MARK: - recent row

/// One tappable "recent read" row in the expanded pill. The *title* gets the
/// full width (single line, tail-truncated); the relative age sits in a
/// de-emphasised trailing slot. The leading glyph flips replay→play and the
/// row lights up on hover so it reads as a tap target. (We deliberately drop
/// the voice prefix that `RecentItem.displayLine()` carries for the menu —
/// the pill already shows the active voice, so repeating it per row just ate
/// the horizontal room the title needs.)
private struct PillRecentRow: View {
    let item: RecentItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: hovering ? "play.fill" : "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                    .frame(width: 14, height: 14)
                Text(item.title)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(item.ageString())
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Re-speak")
        // Swallow the parent tap-to-pin so a row tap doesn't toggle the pin.
        .simultaneousGesture(TapGesture().onEnded {})
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
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
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
