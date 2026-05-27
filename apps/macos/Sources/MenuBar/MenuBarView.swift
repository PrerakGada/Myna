// MenuBarView.swift — v0.2.1 custom popover replacing the v0.2.0 NSMenu.
//
// The popover is hosted by MenuBarExtra using `.menuBarExtraStyle(.window)`
// (set in MynaApp.swift). In `.window` style SwiftUI hands us a plain
// NSWindow surface — no NSMenu chrome — so we own the entire look:
// dark surface, hero card, disclosure-style sections (which don't
// collapse on poll rebuilds the way NSMenu submenus did), and a custom
// footer.
//
// Polling note: MenuBarController is an ObservableObject with @Published
// properties. We bind via @ObservedObject; SwiftUI's diff handles
// partial updates and our local @State (e.g. `voicesExpanded`) survives
// every refresh tick. This is the architectural fix for the v0.2.0
// "submenus collapse on each poll" bug.
//
// All actions still route through MenuBarController so existing hotkey
// handlers and AppDispatcher hooks work unchanged. The data model
// (PopoverModel + PopoverModelBuilder) is preserved verbatim — only the
// rendering changes.
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var player: AudioPlayer
    @ObservedObject var toastCenter: LangMismatchToastCenter = .shared

    /// Voices loaded lazily — same lazy-pattern as v0.2.0. Held at the
    /// top-level view so the network round-trip happens once per popover
    /// session, not per section render.
    @State private var voices: [Voice] = []

    /// Mirror of the floating-pill master toggle so the popover can
    /// hide the "Reset pill position" row when the pill is disabled.
    /// @AppStorage gives us free UserDefaults binding without a
    /// dependency on PillController / SettingsViewModel.
    @AppStorage("dev.myna.app.showFloatingPill") private var showFloatingPill: Bool = true

    // Section open/closed state. SwiftUI persists this across poll-driven
    // re-renders, which is the whole point of the v0.2.1 redesign.
    @State private var voicesExpanded = false
    @State private var speedExpanded = false
    @State private var ccExpanded = true
    @State private var recentsExpanded = false

    public init(controller: MenuBarController) {
        self.controller = controller
        self.player = controller.player
    }

    public var body: some View {
        let model = controller.popoverModel()
        VStack(alignment: .leading, spacing: PopoverDesign.sectionSpacing) {
            PopoverHeader(iconState: controller.iconState)
            // Transient lang-mismatch hint (only when langid signalled a
            // detected language different from the configured voice's).
            if let metadata = toastCenter.latest, let lang = metadata.detectedLang {
                langMismatchChip(detectedLang: lang)
            }
            heroSection(model: model)
            voiceSection
            speedSection
            if model.showClaudeCodeSubmenu {
                claudeCodeSection(items: model.ccItems)
            }
            if !model.recents.isEmpty {
                recentsSection(items: model.recents)
            }
            if showFloatingPill {
                resetPillPositionRow
            }
            Divider()
                .overlay(Color.white.opacity(0.08))
                .padding(.horizontal, -PopoverDesign.popoverHorizontalPadding)
            FooterBar(
                updates: controller.updates,
                onSettings: controller.openSettings,
                onWhatsNew: { WhatsNewLauncher.shared.show() },
                onRestartDaemon: controller.restartDaemon,
                onOpenLogs: controller.openLogs
            )
        }
        .padding(.horizontal, PopoverDesign.popoverHorizontalPadding)
        .padding(.vertical, PopoverDesign.popoverVerticalPadding)
        .frame(width: PopoverDesign.popoverWidth, alignment: .leading)
        .background(PopoverDesign.surface)
        .task { await loadVoices() }
    }

    // MARK: - lang-mismatch chip
    //
    // Small dismissible row that appears at the top of the popover when
    // the daemon's langid detector signalled `X-Myna-Lang-Mismatch: 1`
    // on the last synthesize. Tapping the chip opens Settings (where the
    // user can change voice or wire a Voice Wardrobe rule); the × dismisses
    // the toast for this session. Intentionally minimal — full UX (slide-in
    // animation, snooze, "switch voice" inline action) belongs in v0.3.
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
            controller.openSettings()
            toastCenter.dismiss()
        }
    }

    // MARK: - hero (Now Playing / Idle / Error)

    @ViewBuilder
    private func heroSection(model: PopoverModel) -> some View {
        switch model.status {
        case .idle:
            IdleHero(speakHotkey: HotkeyLabel.display(for: .speakSelectionFull))
        case .loading(let title):
            LoadingHero(previewTitle: title)
        case .playing(let nr):
            NowPlayingCard(
                nowReading: nr,
                isPaused: false,
                pauseHotkey: HotkeyLabel.display(for: .pauseResume),
                stopHotkey: HotkeyLabel.display(for: .stop),
                onTogglePause: controller.togglePause,
                onStop: controller.stopPlayback,
                onSkipBack: { controller.seek(delta: -15) },
                onSkipForward: { controller.seek(delta: 15) }
            )
        case .paused(let nr):
            NowPlayingCard(
                nowReading: nr,
                isPaused: true,
                pauseHotkey: HotkeyLabel.display(for: .pauseResume),
                stopHotkey: HotkeyLabel.display(for: .stop),
                onTogglePause: controller.togglePause,
                onStop: controller.stopPlayback,
                onSkipBack: { controller.seek(delta: -15) },
                onSkipForward: { controller.seek(delta: 15) }
            )
        case .error(let msg):
            ErrorHero(message: msg)
        }
    }

    // MARK: - VOICE

    @ViewBuilder
    private var voiceSection: some View {
        let currentLabel = currentVoiceLabel()
        VStack(spacing: 6) {
            SectionHeader(
                title: "Voice",
                trailing: currentLabel,
                trailingColor: PopoverDesign.bodyColor,
                isExpanded: $voicesExpanded
            )
            if voicesExpanded {
                voiceGrid
            }
        }
    }

    @ViewBuilder
    private var voiceGrid: some View {
        if voices.isEmpty {
            HoverableRow(
                cornerRadius: 6,
                horizontalPadding: 8,
                verticalPadding: 8,
                action: { Task { await loadVoices() } },
                content: {
                    Text("Refresh voice list")
                        .font(PopoverDesign.bodyFont)
                        .foregroundStyle(PopoverDesign.bodyColor)
                }
            )
        } else {
            let columns = [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6),
            ]
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(voices) { voice in
                    VoiceTile(
                        voice: voice,
                        isSelected: controller.settings?.voice == voice.id,
                        onSelect: { controller.settings?.voice = voice.id }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func currentVoiceLabel() -> String {
        guard let id = controller.settings?.voice else { return "—" }
        if let match = voices.first(where: { $0.id == id }) {
            return match.label
        }
        return id
    }

    // MARK: - SPEED

    @ViewBuilder
    private var speedSection: some View {
        let value = player.speed
        VStack(spacing: 6) {
            SectionHeader(
                title: "Speed",
                trailing: String(format: "%.2g×", value),
                trailingColor: PopoverDesign.bodyColor,
                isExpanded: $speedExpanded
            )
            if speedExpanded {
                SpeedChips(current: value) { controller.setSpeed($0) }
                    .padding(.horizontal, 2)
            }
        }
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
                VStack(spacing: 6) {
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

    // MARK: - reset pill position

    /// Tiny inline row that resets the floating-pill's persisted
    /// frame and re-snaps it to bottom-centre of the screen-under-
    /// cursor. Posts a Notification so MenuBarView doesn't need to
    /// hold a reference to PillController (which would require
    /// plumbing through MynaApp — outside this lane's allow-list).
    @ViewBuilder
    private var resetPillPositionRow: some View {
        HoverableRow(
            cornerRadius: 6,
            horizontalPadding: 8,
            verticalPadding: 6,
            action: {
                NotificationCenter.default.post(
                    name: PillController.resetPositionNotification,
                    object: nil
                )
            },
            content: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.left.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PopoverDesign.bodyColor.opacity(0.8))
                    Text("Reset pill position")
                        .font(PopoverDesign.bodyFont)
                        .foregroundStyle(PopoverDesign.bodyColor)
                }
            }
        )
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
