// DashboardView.swift — the Dashboard's root: sidebar + pane.
//
// Deliberately NOT NavigationSplitView. On macOS 13 that scene type
// insists on its own translucent sidebar material and its own list
// selection chrome, both of which fight the near-black visual system the
// rest of Myna uses, and its collapse behaviour is not something this
// window wants. A plain HStack of two columns gives full control for
// about the same amount of code.
import SwiftUI

struct DashboardView: View {
    let context: DashboardContext
    @ObservedObject var launcher: DashboardLauncher

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(
                selection: $launcher.pane,
                player: context.player,
                history: context.history,
                menuController: context.menuController
            )
            Rectangle()
                .fill(DashboardDesign.separator)
                .frame(width: 1)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DashboardDesign.surface)
        .frame(
            minWidth: DashboardDesign.minWindowWidth,
            minHeight: DashboardDesign.minWindowHeight
        )
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var pane: some View {
        switch launcher.pane {
        case .overview:
            OverviewPane(history: context.history, onOpenHistory: { launcher.pane = .history })
        case .history:
            HistoryPane(
                history: context.history, menuController: context.menuController, client: context.client,
                daemonURL: context.settings.fullDaemonBaseURL ?? DaemonClient.defaultBaseURL)
        case .playground:
            PlaygroundPane(context: context, launcher: launcher)
        case .studio:
            StudioPane(context: context, launcher: launcher)
        case .api:
            APIPane(context: context, launcher: launcher)
        case .voices:
            VoicesPane(
                client: context.client,
                settings: context.settings,
                player: context.player,
                history: context.history,
                onOpenEngines: { launcher.pane = .daemon }
            )
        case .pronunciation:
            PronunciationPane(baseURL: context.settings.fullDaemonBaseURL ?? DaemonClient.defaultBaseURL)
        case .shortcuts:
            ShortcutsPane()
        case .reading:
            ReadingPane(settings: context.settings)
        case .gestures:
            GesturesPane(settings: context.settings)
        case .wardrobe:
            WardrobePane(client: context.client)
        case .daemon:
            EnginePane(
                client: context.client,
                settings: context.settings,
                menuController: context.menuController,
                player: context.player
            )
        case .logs:
            LogsPane()
        case .account:
            AccountPane(history: context.history, updates: context.updates, settings: context.settings)
        }
    }
}

// MARK: - sidebar

private struct DashboardSidebar: View {
    @Binding var selection: DashboardPane
    @ObservedObject var player: AudioPlayer
    @ObservedObject var history: HistoryStore
    @ObservedObject var menuController: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(DashboardPane.Group.allCases) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            DashSectionTitle(group.title)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 4)
                            ForEach(group.panes) { pane in
                                SidebarRow(
                                    pane: pane,
                                    isSelected: selection == pane,
                                    badge: badge(for: pane)
                                ) {
                                    selection = pane
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            Spacer(minLength: 0)
            NowPlayingStrip(player: player, menuController: menuController)
        }
        .frame(width: DashboardDesign.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(DashboardDesign.sidebarSurface)
    }

    /// Only History carries a count — a number next to every row is noise.
    private func badge(for pane: DashboardPane) -> String? {
        guard pane == .history, !history.events.isEmpty else { return nil }
        return HistoryAnalytics.compactCount(history.events.count)
    }

    private var header: some View {
        HStack(spacing: 9) {
            BirdIcon.image
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(DashboardDesign.title)
            VStack(alignment: .leading, spacing: 0) {
                Text("Myna")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DashboardDesign.title)
                Text("v\(Self.appVersion)")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardDesign.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        // Clears the transparent title bar's traffic lights.
        .padding(.top, 34)
        .padding(.bottom, 10)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

private struct SidebarRow: View {
    let pane: DashboardPane
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17, alignment: .center)
                    .foregroundStyle(
                        isSelected ? DashboardDesign.accent : DashboardDesign.secondary)
                Text(pane.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? DashboardDesign.title : DashboardDesign.body)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(DashboardDesign.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovering = $0 }
        .help(pane.subtitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        if isSelected { return Color.white.opacity(0.10) }
        if isHovering { return Color.white.opacity(0.05) }
        return .clear
    }
}

/// Persistent transport at the foot of the sidebar. The whole point of a
/// window you leave open is that you can stop a read without hunting for
/// the menu bar.
private struct NowPlayingStrip: View {
    @ObservedObject var player: AudioPlayer
    @ObservedObject var menuController: MenuBarController
    @ObservedObject var queue: ReadQueue = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DashboardDesign.separator).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DashboardDesign.secondary)
                        .lineLimit(1)
                    QueuedCountText(queue: queue)
                    TranscriptStripButton()
                }
                if player.state != .idle || player.isLoading {
                    Text(menuController.lastReadTitle ?? "—")
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardDesign.body)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        TransportButton(
                            systemImage: player.state == .paused ? "play.fill" : "pause.fill",
                            help: player.state == .paused ? "Resume" : "Pause"
                        ) { menuController.togglePause() }
                        TransportButton(systemImage: "stop.fill", help: "Stop") {
                            menuController.stopPlayback()
                        }
                        TransportButton(systemImage: "gobackward.15", help: "Back 15 seconds") {
                            menuController.seek(delta: -15)
                        }
                        TransportButton(systemImage: "goforward.15", help: "Forward 15 seconds") {
                            menuController.seek(delta: 15)
                        }
                        if !queue.items.isEmpty {
                            TransportButton(systemImage: "forward.end.fill", help: "Skip to the next read") {
                                queue.skip()
                            }
                        }
                        Spacer(minLength: 0)
                        Text(timeCode)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private var statusLabel: String {
        if player.isLoading { return "Preparing…" }
        switch player.state {
        case .playing: return "Speaking"
        case .paused: return "Paused"
        case .idle: return menuController.reachability == .down ? "Engine unreachable" : "Idle"
        }
    }

    private var dotColor: Color {
        if player.isLoading { return DashboardDesign.warning }
        switch player.state {
        case .playing: return DashboardDesign.positive
        case .paused: return DashboardDesign.info
        case .idle:
            return menuController.reachability == .down
                ? DashboardDesign.negative : DashboardDesign.tertiary
        }
    }

    private var timeCode: String {
        guard player.duration > 0 else { return "" }
        return "\(HistoryAnalytics.durationString(player.position)) / "
            + HistoryAnalytics.durationString(player.duration)
    }
}

private struct TransportButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovering ? DashboardDesign.title : DashboardDesign.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovering ? Color.white.opacity(0.09) : Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}
