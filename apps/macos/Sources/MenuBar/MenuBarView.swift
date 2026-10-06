// MenuBarView.swift — the menu-bar popover.
//
// Hosted by MenuBarExtra using `.menuBarExtraStyle(.window)` (set in
// MynaApp.swift). In `.window` style SwiftUI hands us a plain NSWindow
// surface — no NSMenu chrome — so we own the entire look.
//
// Polling note: MenuBarController is an ObservableObject with @Published
// properties. We bind via @ObservedObject; SwiftUI's diff handles partial
// updates and our local @State (e.g. `ccExpanded`) survives every
// refresh tick. This is the architectural fix for the v0.2.0 "submenus
// collapse on each poll" bug, and it's why sections here are SwiftUI
// disclosure state rather than NSMenu submenus.
//
// ── v0.6 rework ──────────────────────────────────────────────────────
// The v0.2.1 popover was a readout: it told you the state and then told
// you which keyboard shortcut to press. Four of its rows were accordions
// hiding a single value each, "Reset pill position" sat at top level as
// an orphaned debug row, and the footer ranked Quit, Open Logs and
// Settings as equally likely. What changed:
//
//   • Quick actions — the popover can now start a read (clipboard, a
//     summary of it, or the front Chrome tab). See QuickActions.swift
//     for why "read selection" is deliberately not among them.
//   • The 130pt idle hero is gone; idle is the action row plus one line.
//   • Voice and speed share one row (VoiceSpeedRow): two menus and a
//     preview glyph. They used to be a tile grid plus a chip row, ~150pt
//     for two settings that are set once and left alone.
//   • OPTIONS carries the toggles that used to need the seven-tab
//     Settings window, and absorbs the orphaned pill row.
//   • An engine-down warning strip: the bird already went red for this,
//     but the popover went on saying READY.
//
// All actions still route through MenuBarController, so hotkey handlers
// and AppDispatcher hooks work unchanged.
import AppKit
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var player: AudioPlayer
    @ObservedObject var toastCenter: LangMismatchToastCenter = .shared
    @ObservedObject var readQueue: ReadQueue = .shared

    /// Voice previews, played at -6dB with the main playback ducked to 30%.
    /// Same service the Settings Voice tab uses; the popover just never had
    /// one, so its tiles rendered without the preview affordance.
    @StateObject private var voicePreview: VoicePreviewService

    /// Voices loaded lazily — the network round-trip happens once per
    /// popover session, not per section render.
    @State private var voices: [Voice] = []

    // Section open/closed state. SwiftUI persists this across poll-driven
    // re-renders, which is the whole point of the v0.2.1 architecture.
    @State private var ccExpanded = true
    @State private var recentsExpanded = false
    @State private var optionsExpanded = false

    public init(controller: MenuBarController) {
        self.controller = controller
        self.player = controller.player
        _voicePreview = StateObject(
            wrappedValue: VoicePreviewService(client: controller.client, sink: controller.player)
        )
    }

    public var body: some View {
        let model = controller.popoverModel()
        // Fixed height: the sections scroll inside it and the footer is
        // pinned underneath, so the window no longer grows and shrinks as
        // sections open, and Quit / Updates never scroll out of reach.
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: PopoverDesign.sectionSpacing) {
                    PopoverHeader(iconState: controller.iconState)
                    if model.engineWarning {
                        EngineWarningStrip(onRestart: controller.restartDaemon)
                    }
                    if let metadata = toastCenter.latest, let lang = metadata.detectedLang {
                        langMismatchChip(detectedLang: lang)
                    }
                    heroSection(model: model)
                    if !readQueue.items.isEmpty {
                        QueueSection(queue: readQueue)
                    }
                    actionsSection(model: model)
                    voiceSpeedRow
                    if model.showClaudeCodeSubmenu {
                        claudeCodeSection(items: model.ccItems)
                    }
                    if !model.recents.isEmpty {
                        recentsSection(items: model.recents)
                    }
                    optionsSection
                }
                .padding(.horizontal, PopoverDesign.popoverHorizontalPadding)
                .padding(.vertical, PopoverDesign.popoverVerticalPadding)
                .frame(width: PopoverDesign.popoverWidth, alignment: .leading)
            }
            FeedbackRow()
                .padding(.horizontal, PopoverDesign.popoverHorizontalPadding - 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
                .overlay(Color.white.opacity(0.08))
            FooterBar(
                updates: controller.updates,
                onDashboard: { controller.openDashboard() },
                onWhatsNew: Self.openWhatsNew
            )
            .padding(.horizontal, PopoverDesign.popoverHorizontalPadding)
            .padding(.vertical, 8)
        }
        .frame(width: PopoverDesign.popoverWidth, height: Self.popoverHeight)
        .background(PopoverDesign.surface)
        .task { await loadVoices() }
        // A preview left running after the popover closes keeps the main
        // playback ducked to 30% with nothing visible to explain why.
        .onDisappear { voicePreview.cancel() }
    }

    // MARK: - popover sizing

    /// The design height, clamped to the usable screen height. `visibleFrame`
    /// already excludes the menu bar and Dock; the margin keeps the popover
    /// off the screen edge on a small display.
    private static var popoverHeight: CGFloat {
        let usable = NSScreen.main?.visibleFrame.height ?? 800
        return min(PopoverDesign.popoverHeight, max(320, usable - 24))
    }

    /// Open the public changelog / release notes on the website. The
    /// in-app "What's New" window is reserved for the auto-shown upgrade
    /// dialog; the footer button points at the site instead.
    static func openWhatsNew() {
        guard let url = URL(string: "https://myna.prerakgada.in") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - lang-mismatch chip
    //
    // Appears when the daemon's langid detector signalled
    // `X-Myna-Lang-Mismatch: 1` on the last synthesize. Tapping opens
    // Settings (change voice, or wire a Voice Wardrobe rule); the × dismisses
    // for this session.
    @ViewBuilder
    private func langMismatchChip(detectedLang: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.tint)
            Text("Detected: \(detectedLang.uppercased()) — adjust voice in Settings")
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 4)
            Button(action: { toastCenter.dismiss() }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Dismiss")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss language hint")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .onTapGesture {
            controller.openDashboard(pane: .voices)
            toastCenter.dismiss()
        }
    }

    // MARK: - hero (Now Playing / Preparing / Error)
    //
    // Idle renders nothing. The quick-action row below is the idle hero —
    // the card that used to live here existed only to say "No audio playing".

    @ViewBuilder
    private func heroSection(model: PopoverModel) -> some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .loading(let title):
            LoadingHero(previewTitle: title)
        case .playing(let nowReading):
            nowPlaying(nowReading, isPaused: false)
        case .paused(let nowReading):
            nowPlaying(nowReading, isPaused: true)
        case .error(let msg):
            ErrorHero(
                message: msg,
                onSetup: { _ = SetupLauncher.shared.present() },
                onRestart: controller.restartDaemon
            )
        }
    }

    private func nowPlaying(_ nowReading: PopoverModel.NowReading, isPaused: Bool) -> some View {
        NowPlayingCard(
            nowReading: nowReading,
            isPaused: isPaused,
            pauseHotkey: HotkeyLabel.display(for: .pauseResume),
            stopHotkey: HotkeyLabel.display(for: .stop),
            onTogglePause: controller.togglePause,
            onStop: controller.stopPlayback,
            onSkipBack: { controller.seek(delta: -15) },
            onSkipForward: { controller.seek(delta: 15) },
            onNext: readQueue.items.isEmpty ? nil : { readQueue.skip() },
            nextHotkey: HotkeyLabel.display(for: .skipToNext)
        )
    }

    // MARK: - quick actions

    @ViewBuilder
    private func actionsSection(model: PopoverModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QuickActions(
                clipboard: ClipboardProbe.text(),
                // Daemon unreachable or engine down: a read started now
                // would spin and fail, so don't invite it.
                isEnabled: !model.engineWarning && !isDaemonError(model),
                onReadClipboard: { controller.readClipboard(mode: .full) },
                onSummarizeClipboard: { controller.readClipboard(mode: .summary) },
                onReadChrome: controller.readChromeTab
            )
            if model.status.isIdle {
                ReadyHint(speakHotkey: HotkeyLabel.display(for: .speakSelectionFull))
            }
        }
    }

    private func isDaemonError(_ model: PopoverModel) -> Bool {
        if case .error = model.status { return true }
        return false
    }

    // MARK: - VOICE + SPEED
    //
    // One row. Both are set once and left alone, so they get a line, not
    // a section each.

    @ViewBuilder
    private var voiceSpeedRow: some View {
        VStack(spacing: 4) {
            VoiceSpeedRow(
                voices: voices,
                selectedVoiceId: controller.settings?.voice,
                speed: player.speed,
                onSelectVoice: { controller.settings?.voice = $0 },
                onPreview: {
                    if let id = controller.settings?.voice {
                        voicePreview.preview(voiceId: id)
                    }
                },
                onSelectSpeed: { controller.setSpeed($0) },
                onRefreshVoices: { Task { await loadVoices() } }
            )
            previewStatusLine
        }
    }

    /// Mirrors the Settings tab's inline preview feedback. A cold engine
    /// takes a couple of seconds to answer the first preview, and silence
    /// is indistinguishable from a dead button.
    @ViewBuilder
    private var previewStatusLine: some View {
        switch voicePreview.state {
        case .warming:
            previewNote("Engine warming…", color: PopoverDesign.dotThinking)
        case .failed:
            previewNote("Couldn't play that preview.", color: PopoverDesign.dotError)
        case .loading, .playing, .idle:
            EmptyView()
        }
    }

    private func previewNote(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PopoverDesign.captionFont)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - CLAUDE CODE

    @ViewBuilder
    private func claudeCodeSection(items: [RegistryV2Item]) -> some View {
        VStack(spacing: 6) {
            SectionHeader(
                title: "Claude Code",
                trailing: "\(items.count)",
                trailingColor: PopoverDesign.bodyColor,
                isExpanded: $ccExpanded
            )
            if ccExpanded {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        CCToastCard(
                            item: item,
                            onPlay: { controller.play(item: item) },
                            onDiscard: { controller.discard(item: item) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - RECENT

    @ViewBuilder
    private func recentsSection(items: [RecentItem]) -> some View {
        VStack(spacing: 4) {
            SectionHeader(
                title: "Recent",
                trailing: "\(items.count)",
                isExpanded: $recentsExpanded
            )
            if recentsExpanded {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        RecentRow(item: item) { controller.replayRecent(item) }
                    }
                }
            }
        }
    }

    // MARK: - OPTIONS

    @ViewBuilder
    private var optionsSection: some View {
        if let settings = controller.settings {
            VStack(spacing: 6) {
                SectionHeader(title: "Options", isExpanded: $optionsExpanded)
                if optionsExpanded {
                    OptionsSection(
                        settings: settings,
                        onRestartDaemon: controller.restartDaemon,
                        onOpenLogs: controller.openLogs,
                        onOpenSettings: { controller.openDashboard(pane: .shortcuts) }
                    )
                }
            }
        }
    }

    // MARK: - voice loading

    private func loadVoices() async {
        do {
            voices = try await controller.client.voices()
        } catch {
            // Quietly leave empty — user can hit "Refresh voice list".
        }
    }
}
