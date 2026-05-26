// MenuBarView.swift — the SwiftUI menu displayed when the user clicks
// the bird in the menu bar. v0.2 redesigns this per Sally's spec
// (03-ux-direction.md § 1):
//
//   Top:    Now Reading header (collapses to "No audio playing" when idle)
//   Mid:    Transport block with current hotkey labels (hidden when idle)
//   Then:   Voice ▸, Speed ▸, Recent ▸, Claude Code ▸ (if non-empty)
//   Foot:   Settings…, What's New…, Restart Daemon, Quit
//
// State comes from MenuBarController.popoverModel() — a pure
// transformation of the controller's @Published state. Tests assert
// against the model, not against rendered SwiftUI.
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var player: AudioPlayer

    /// Voices loaded lazily for the Voice submenu. Kept here (not in
    /// the controller) because Voice is purely cosmetic — switching
    /// voices doesn't change anything until the next utterance.
    @State private var voices: [Voice] = []

    public init(controller: MenuBarController) {
        self.controller = controller
        self.player = controller.player
    }

    public var body: some View {
        let model = controller.popoverModel()
        nowReadingSection(model: model)
        if !model.status.isIdle && !isError(model.status) {
            Divider()
            transportSection(model: model)
        }
        if isError(model.status) {
            Divider()
            errorSection(model.status)
        }
        Divider()
        voiceMenu
        speedMenu
        Divider()
        recentsMenu(items: model.recents)
        if model.showClaudeCodeSubmenu {
            claudeCodeMenu(items: model.ccItems)
        }
        Divider()
        settingsFooter
        Divider()
        Button("Quit Myna") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: - sections

    @ViewBuilder
    private func nowReadingSection(model: PopoverModel) -> some View {
        switch model.status {
        case .idle:
            Text("No audio playing")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .playing(let nr), .paused(let nr):
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    model.status.nowReading == nil ? "Now reading" : (isPaused(model.status) ? "Paused" : "Now reading")
                )
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                Text(nr.truncatedTitle)
                    .font(.caption)
                Text(nr.formattedMetadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .error(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func transportSection(model: PopoverModel) -> some View {
        ForEach(model.transport) { row in
            transportButton(row)
        }
    }

    private func transportButton(_ row: PopoverModel.TransportRow) -> some View {
        Button {
            switch row.id {
            case .pause: controller.togglePause()
            case .stop: controller.stopPlayback()
            case .skipForward: controller.seek(delta: 15)
            case .skipBack: controller.seek(delta: -15)
            }
        } label: {
            HStack {
                Text(row.title)
                if let label = row.hotkeyLabel {
                    Spacer()
                    Text(label).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!row.isEnabled)
    }

    @ViewBuilder
    private func errorSection(_ status: PopoverModel.Status) -> some View {
        if case .error(let msg) = status {
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var voiceMenu: some View {
        Menu("Voice") {
            if voices.isEmpty {
                Button("Refresh voice list") {
                    Task { await loadVoices() }
                }
            } else {
                ForEach(voices) { voice in
                    Button {
                        controller.settings?.voice = voice.id
                    } label: {
                        HStack {
                            Text(voice.label)
                            if controller.settings?.voice == voice.id {
                                Spacer()
                                Text("✓")
                            }
                        }
                    }
                }
            }
        }
        .task { await loadVoices() }
    }

    @ViewBuilder
    private var speedMenu: some View {
        Menu("Speed") {
            // AVAudioUnitTimePitch's `.rate` parameter hard-caps at 2.0× — values
            // above silently clamp. See TimePitchUnit.maxRate.
            ForEach([0.75, 1.0, 1.2, 1.5, 1.75, 2.0], id: \.self) { value in
                Button {
                    controller.setSpeed(value)
                } label: {
                    HStack {
                        Text(String(format: "%.2fx", value))
                        if abs(controller.player.speed - value) < 0.01 {
                            Spacer()
                            Text("✓")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recentsMenu(items: [RecentItem]) -> some View {
        Menu("Recent") {
            if items.isEmpty {
                Text("No recent reads")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    Button(item.displayLine()) {
                        controller.replayRecent(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func claudeCodeMenu(items: [RegistryV2Item]) -> some View {
        Menu("Claude Code (\(items.count))") {
            ForEach(items) { item in
                Menu(item.preview()) {
                    Button("Play") {
                        controller.play(item: item)
                    }
                    Button("Discard") {
                        controller.discard(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var settingsFooter: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") { controller.openSettings() }
        }
        Button("What's New…") {
            WhatsNewLauncher.shared.show()
        }
        Button("Restart Daemon") {
            controller.restartDaemon()
        }
        Button("Open Logs") { controller.openLogs() }
        CheckForUpdatesMenuItem(controller.updates)
    }

    private func loadVoices() async {
        do {
            voices = try await controller.client.voices()
        } catch {
            // Quietly leave empty — user can hit "Refresh" again.
        }
    }

    private func isError(_ status: PopoverModel.Status) -> Bool {
        if case .error = status { return true }
        return false
    }

    private func isPaused(_ status: PopoverModel.Status) -> Bool {
        if case .paused = status { return true }
        return false
    }
}
