// PillView.swift — the SwiftUI floating-pill UI.
//
// One root that switches on `viewModel.layout` (the FSM from PillState.swift):
//   • collapsedIdle      → bird badge + "Myna"
//   • processing         → bird badge + "Processing…" + mini spinner
//   • collapsedPlaying   → bird badge + status + Core-Animation waveform
//   • caption            → live captions: the sentence being read, its
//                          spoken word lit (PillCaption.swift)
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

enum PillStyle {
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
            CollapsedBar(kind: viewModel.showsPaused ? .paused : .playing)
        case .caption:
            if let caption = viewModel.caption {
                PillCaptionCard(caption: caption)
            } else {
                CollapsedBar(kind: viewModel.showsPaused ? .paused : .playing)
            }
        case .expanded, .promptCTA:
            // promptCTA falls back to the expanded mini-player until Step 8.
            expanded
        }
    }

    private var accessibilityLabel: String {
        if viewModel.showsPaused { return "Myna paused" }
        if viewModel.isSpeaking || viewModel.isDaemonReading { return "Myna speaking" }
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
        if viewModel.showsPaused { return "Paused" }
        if viewModel.isSpeaking || viewModel.isDaemonReading { return "Speaking\u{2026}" }
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
                        if let queued = viewModel.queuedLabel {
                            queueChip(queued)
                        }
                        if viewModel.isLoading && !viewModel.isSpeaking {
                            trailingIndicator(.spinner, height: 10)
                                .matchedGeometryEffect(id: "waveform", in: ns)
                        } else if viewModel.isSpeaking || viewModel.isDaemonReading {
                            trailingIndicator(.waveform(playing: !viewModel.showsPaused), height: 10)
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

            // What Myna is reading, word by word (live captions on).
            if viewModel.captionsOn, let caption = viewModel.caption {
                PillCaptionText(caption: caption)
            }

            // Scrubber + transport (only with a live session to control).
            // A daemon read (Claude Code's Myna controls) can only pause and stop.
            if viewModel.isSpeaking {
                scrubberRow
                controlsRow
            } else if viewModel.isDaemonReading {
                daemonControlsRow
            }

            // Recent reads — pinned only (keeps the hover footprint small).
            if viewModel.isPinned && !viewModel.recents.isEmpty {
                transcriptList
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: PillStyle.expandedWidth, alignment: .leading)
        .background(PillChrome(cornerRadius: PillStyle.expandedRadius))
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

    private func queueChip(_ label: String) -> some View {
        Text(label)
            .font(PillStyle.chipFont)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .help("Reads waiting their turn. Open the menu to see or remove them.")
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
            transportButton(system: "stop.fill", size: 12, help: "Stop and clear the queue") {
                viewModel.stop()
            }
            if viewModel.queuedLabel != nil {
                transportButton(system: "forward.end.fill", size: 12, help: "Skip to the next read") {
                    viewModel.skipToNext()
                }
            }
            TranscriptPillButton()
            Spacer(minLength: 0)
            speedButton
        }
    }

    private var daemonControlsRow: some View {
        HStack(spacing: 12) {
            transportButton(
                system: viewModel.isDaemonPaused ? "play.fill" : "pause.fill",
                size: 16,
                help: viewModel.isDaemonPaused ? "Resume" : "Pause"
            ) { viewModel.togglePlayPause() }
            transportButton(system: "stop.fill", size: 12, help: "Stop") {
                viewModel.stop()
            }
            Spacer(minLength: 0)
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
        BirdIcon.filledImage
            .resizable()
            .scaledToFit()
            .frame(width: diameter * 0.58, height: diameter * 0.58)
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
