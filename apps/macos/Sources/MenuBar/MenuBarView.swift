// MenuBarView.swift — the SwiftUI menu displayed when the user clicks
// the bird in the menu bar. Mirrors the v1 hammerspoon menu structure
// for behavioural compatibility, plus the new playback controls.
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var controller: MenuBarController
    @ObservedObject var player: AudioPlayer

    public init(controller: MenuBarController) {
        self.controller = controller
        self.player = controller.player
    }

    public var body: some View {
        // Header: daemon + engine reachability summary.
        headerSection
        Divider()

        // Transport.
        transportSection
        speedMenu
        seekMenu
        Divider()

        // Registry.
        registrySection
        Divider()

        // Settings + about.
        Button("Customize Shortcuts…") { controller.openSettings() }
        Button("Settings…") { controller.openSettings() }
        Button("Open Logs") { controller.openLogs() }
        CheckForUpdatesMenuItem(controller.updates)
        Divider()
        Button("Quit Myna") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var headerSection: some View {
        switch controller.reachability {
        case .up:
            if let status = controller.status {
                Text("Daemon \(status.daemon.version) · engine \(status.engine.status)")
                    .font(.caption)
            } else {
                Text("Daemon: up").font(.caption)
            }
        case .down:
            Text("Daemon: down").font(.caption).foregroundStyle(.red)
        case .unknown:
            Text("Daemon: checking…").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var transportSection: some View {
        switch player.state {
        case .paused:
            Button("Resume") { controller.togglePause() }
        case .playing:
            Button("Pause") { controller.togglePause() }
        case .idle:
            Button("Pause") {}.disabled(true)
        }
        Button("Stop") { controller.stopPlayback() }
            .disabled(player.state == .idle)
    }

    @ViewBuilder
    private var speedMenu: some View {
        Menu("Speed") {
            ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                Button(String(format: "%.2fx", value)) {
                    controller.setSpeed(value)
                }
            }
        }
    }

    @ViewBuilder
    private var seekMenu: some View {
        Menu("Seek") {
            Button("- 15s") { controller.seek(delta: -15) }
            Button("+ 15s") { controller.seek(delta: 15) }
            Button("- 30s") { controller.seek(delta: -30) }
            Button("+ 30s") { controller.seek(delta: 30) }
        }
        .disabled(player.duration == 0)
    }

    @ViewBuilder
    private var registrySection: some View {
        if controller.registry.isEmpty {
            Text("No Claude output waiting").foregroundStyle(.secondary)
        } else {
            ForEach(controller.registry) { item in
                Menu(label(for: item)) {
                    Button("▶ Full") { controller.playRegistry(item: item, mode: .full) }
                    Button("✦ Summary") { controller.playRegistry(item: item, mode: .summary) }
                }
            }
        }
    }

    private func label(for item: RegistryItem) -> String {
        "\(item.label) · \(item.ageS)s — \(item.preview)"
    }
}
