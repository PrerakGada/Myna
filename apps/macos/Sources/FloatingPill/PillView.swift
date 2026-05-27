// PillView.swift — the SwiftUI pill UI.
//
// Two states sharing one rounded-pill container:
//   - collapsed: bird glyph + "Speaking…" + 3-dot waveform
//   - expanded: preview text + voice chip + transport + close button
//
// Transition: matchedGeometryEffect on the outer Capsule shape gives
// a smooth grow/shrink without manual frame math.
//
// CRITICAL: the waveform animation MUST NOT use TimelineView. A prior
// implementation drove a TimelineView at 60Hz here and pegged a CPU
// core at 99.5%. We use a CAReplicatorLayer driven by CABasicAnimation
// instead — Core Animation runs the animation on the render server,
// not the main thread, so app CPU stays at ~0% while the pill is
// visible. See ../../Tests/* and the prompt for context.
import AppKit
import SwiftUI

// MARK: - design tokens

/// Local design tokens for the pill. Intentionally self-contained so
/// the FloatingPill module stays independent of the (still-evolving)
/// shared PopoverDesign module. Mirror values where they overlap so
/// the pill reads as part of the same family as the menu-bar popover.
private enum Pill {
    // sizes
    static let collapsedHeight: CGFloat = 28
    static let collapsedHorizontalPadding: CGFloat = 12
    static let expandedHeight: CGFloat = 64
    static let expandedWidth: CGFloat = 360
    static let cornerRadius: CGFloat = 14  // half of collapsed height
    static let expandedCornerRadius: CGFloat = 18

    // typography
    static let statusFont = Font.system(size: 12, weight: .medium, design: .rounded)
    static let previewFont = Font.system(size: 13, weight: .regular, design: .rounded)
    static let chipFont = Font.system(size: 10, weight: .semibold, design: .rounded)

    // animation
    static let transition: Animation = .spring(response: 0.28, dampingFraction: 0.85)
    static let visibilityTransition: Animation = .easeInOut(duration: 0.18)

    // colors — these resolve light/dark mode automatically via NSColor.
    static let background = Color(nsColor: .windowBackgroundColor).opacity(0.001) // placeholder; real fill is the material
    static let foreground = Color.primary
    static let secondaryForeground = Color.secondary
    static let accent = Color.accentColor

    // waveform
    static let waveformDotSize: CGFloat = 3.5
    static let waveformDotSpacing: CGFloat = 4
    static let waveformDotCount: Int = 3
}

// MARK: - root

public struct PillView: View {
    @ObservedObject var viewModel: PillViewModel
    @Namespace private var pillNamespace

    public init(viewModel: PillViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        // Visibility tier: outer container always exists; alpha is 0
        // when not speaking so the layout settles before the panel
        // is shown by PillController.
        Group {
            if viewModel.isExpanded {
                expanded
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                collapsed
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(Pill.transition, value: viewModel.isExpanded)
        .onHover { hovering in
            viewModel.isHovering = hovering
        }
        // Click anywhere on the collapsed/expanded body (except the
        // close button) to pin/unpin.
        .onTapGesture {
            viewModel.togglePin()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if viewModel.isPaused { return "Myna paused" }
        if viewModel.isSpeaking { return "Myna speaking" }
        return "Myna"
    }

    // MARK: - collapsed

    /// Status label shown next to the bird in the collapsed pill.
    /// "Processing" during the pre-audio loading window (Lane 1 ~50ms
    /// responsiveness), "Paused" when paused, "Speaking" while active,
    /// "Myna" when idle (always-visible mode shows the brand chip).
    /// Loading wins over speaking because it owns the leading edge of
    /// the session — once a chunk arrives we flip to "Speaking" in the
    /// same frame.
    private var collapsedStatusText: String {
        if viewModel.isLoading && !viewModel.isSpeaking { return "Processing" }
        if viewModel.isPaused { return "Paused" }
        if viewModel.isSpeaking { return "Speaking" }
        return "Myna"
    }

    private var collapsed: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Pill.foreground)
                .matchedGeometryEffect(id: "bird", in: pillNamespace)

            Text(collapsedStatusText)
                .font(Pill.statusFont)
                .foregroundStyle(Pill.foreground)
                .matchedGeometryEffect(id: "status", in: pillNamespace)

            // Three-way affordance:
            //   • Loading (pre-audio window) → indeterminate spinner so
            //     the user sees the trigger took effect before audio
            //     arrives. Lane 1 / v0.2.x feature.
            //   • Speaking → animated WaveformDots.
            //   • Idle (only reachable in always-visible mode) → empty
            //     placeholder. A pulsing chip while nothing is playing
            //     reads as "loading" and is wrong UX. matchedGeometry
            //     still needs the anchor so we hold a 0-width Color.
            if viewModel.isLoading && !viewModel.isSpeaking {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Pill.foreground)
                    .frame(width: dotsWidth, height: 12)
                    .matchedGeometryEffect(id: "waveform", in: pillNamespace)
            } else if viewModel.isSpeaking {
                WaveformDots(isPlaying: !viewModel.isPaused)
                    .frame(width: dotsWidth, height: 12)
                    .matchedGeometryEffect(id: "waveform", in: pillNamespace)
            } else {
                Color.clear
                    .frame(width: 0, height: 12)
                    .matchedGeometryEffect(id: "waveform", in: pillNamespace)
            }
        }
        .padding(.horizontal, Pill.collapsedHorizontalPadding)
        .frame(height: Pill.collapsedHeight)
        .background(pillBackground(cornerRadius: Pill.cornerRadius))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var dotsWidth: CGFloat {
        let n = CGFloat(Pill.waveformDotCount)
        return n * Pill.waveformDotSize + (n - 1) * Pill.waveformDotSpacing
    }

    // MARK: - expanded

    /// Headline shown in the expanded pill. Falls back through:
    /// loading (with preview text if available) → bridge preview text →
    /// "Paused" → "Speaking…" → "Myna" (idle). Loading prefers the
    /// dispatcher's preview text so the user can confirm the right
    /// thing is queued before audio starts.
    private var expandedHeadline: String {
        if viewModel.isLoading && !viewModel.isSpeaking {
            return viewModel.previewText ?? "Processing\u{2026}"
        }
        if let text = viewModel.previewText { return text }
        if viewModel.isPaused { return "Paused" }
        if viewModel.isSpeaking { return "Speaking\u{2026}" }
        return "Myna"
    }

    private var expanded: some View {
        HStack(spacing: 10) {
            Image(systemName: "bird")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Pill.foreground)
                .matchedGeometryEffect(id: "bird", in: pillNamespace)

            VStack(alignment: .leading, spacing: 2) {
                Text(expandedHeadline)
                    .font(Pill.previewFont)
                    .foregroundStyle(Pill.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .matchedGeometryEffect(id: "status", in: pillNamespace)
                HStack(spacing: 6) {
                    voiceChip
                    // Same three-way affordance as the collapsed view:
                    //   loading → mini spinner
                    //   speaking with preview text → waveform
                    //   else → zero-width placeholder
                    if viewModel.isLoading && !viewModel.isSpeaking {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .tint(Pill.foreground)
                            .frame(width: dotsWidth, height: 10)
                            .matchedGeometryEffect(id: "waveform", in: pillNamespace)
                    } else if viewModel.isSpeaking && viewModel.previewText != nil {
                        WaveformDots(isPlaying: !viewModel.isPaused)
                            .frame(width: dotsWidth, height: 10)
                            .matchedGeometryEffect(id: "waveform", in: pillNamespace)
                    } else {
                        Color.clear
                            .frame(width: 0, height: 10)
                            .matchedGeometryEffect(id: "waveform", in: pillNamespace)
                    }
                }
            }

            Spacer(minLength: 4)

            // Transport controls only when there's something to
            // control. In always-visible idle mode the right side of
            // the pill is just the close button.
            if viewModel.isSpeaking {
                transportControls
            }
            closeButton
        }
        .padding(.horizontal, 14)
        .frame(width: Pill.expandedWidth, height: Pill.expandedHeight)
        .background(pillBackground(cornerRadius: Pill.expandedCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Pill.expandedCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var voiceChip: some View {
        Text(viewModel.voiceLabel)
            .font(Pill.chipFont)
            .foregroundStyle(Pill.secondaryForeground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.white.opacity(0.08))
            )
    }

    private var transportControls: some View {
        HStack(spacing: 6) {
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PillIconButtonStyle())
            .help(viewModel.isPaused ? "Resume" : "Pause")

            Button {
                viewModel.skipToNextChunk()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PillIconButtonStyle())
            .help("Next chunk")
        }
    }

    private var closeButton: some View {
        // In always-visible idle mode the pill can't actually be
        // "closed" (it stays on screen by user preference) — the
        // button collapses the expanded view instead. Use the
        // chevron-down glyph to make that obvious. In any active
        // session the xmark continues to mean "hide pill UI".
        let glyph = (viewModel.isAlwaysVisible && !viewModel.isSpeaking)
            ? "chevron.down"
            : "xmark"
        let helpText = (viewModel.isAlwaysVisible && !viewModel.isSpeaking)
            ? "Collapse"
            : "Hide pill"
        return Button {
            viewModel.dismiss()
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PillIconButtonStyle())
        .help(helpText)
        // Swallow the parent tap-to-pin gesture so dismissing doesn't
        // also toggle the pin.
        .simultaneousGesture(TapGesture().onEnded {})
    }

    // MARK: - shared bg

    @ViewBuilder
    private func pillBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.30))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 6)
    }
}

// MARK: - icon button style

private struct PillIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.0))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - waveform (Core Animation, NOT TimelineView)

/// Three dots that scale up/down in a staggered loop, driven by
/// CABasicAnimation on a CAReplicatorLayer. The replicator pattern
/// lets us write one animation and replicate the dot N times with a
/// per-dot phase delay — Core Animation handles the rest on the
/// render server, so main-thread CPU stays at ~0%.
///
/// Why not TimelineView: it caused 99.5% CPU pegging in an earlier
/// pill implementation. See the prompt and SC-debug notes.
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
    private static let dotCount = Pill.waveformDotCount
    private static let dotSize = Pill.waveformDotSize
    private static let dotSpacing = Pill.waveformDotSpacing
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
        // Anchor at centre so the scale animation grows symmetrically.
        dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        replicator.instanceCount = Self.dotCount
        replicator.instanceTransform = CATransform3DMakeTranslation(Self.dotSize + Self.dotSpacing, 0, 0)
        replicator.instanceDelay = Self.cycleDuration / Double(Self.dotCount * 2)
        replicator.addSublayer(dot)

        layer?.addSublayer(replicator)
    }

    override func layout() {
        super.layout()
        // Vertically centre the row of dots inside our bounds; anchor
        // the first dot so the centres are at (size/2, height/2),
        // (size/2 + size + spacing, height/2), …
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
            // Snap to a stable mid-scale so the dots remain visible
            // (paused state should look static, not invisible).
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
struct PillView_PreviewModel {
    @MainActor
    static func make(
        isSpeaking: Bool,
        isExpanded: Bool,
        withText: Bool = false,
        paused: Bool = false,
        alwaysVisible: Bool = false
    ) -> PillViewModel {
        // Build a real AudioPlayer + Settings — they're cheap to construct.
        let player = AudioPlayer()
        // Use an in-memory defaults suite so the preview never writes
        // to ~/Library/Preferences.
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
        // Force state for the preview without driving the audio engine.
        vm._previewForceState(
            isSpeaking: isSpeaking,
            isExpanded: isExpanded,
            paused: paused,
            alwaysVisible: alwaysVisible
        )
        return vm
    }
}

#Preview("Collapsed — speaking") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: true, isExpanded: false))
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Collapsed — paused") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: true, isExpanded: false, paused: true))
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Expanded — with text") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: true, isExpanded: true, withText: true))
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Expanded — no text") {
    PillView(viewModel: PillView_PreviewModel.make(isSpeaking: true, isExpanded: true, withText: false))
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Collapsed — idle (always visible)") {
    PillView(viewModel: PillView_PreviewModel.make(
        isSpeaking: false,
        isExpanded: false,
        alwaysVisible: true
    ))
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Expanded — idle (always visible)") {
    PillView(viewModel: PillView_PreviewModel.make(
        isSpeaking: false,
        isExpanded: true,
        alwaysVisible: true
    ))
        .padding(40)
        .background(Color.gray.opacity(0.2))
}
#endif
