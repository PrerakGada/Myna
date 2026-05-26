// FooterBar.swift — bottom row of the popover. Settings · What's New ·
// Check for Updates · Restart Daemon · Open Logs · Quit.
//
// We render the actions as compact icon-plus-label rows so the popover
// can host all of them without becoming wider. Hover lights them like
// the rest of the popover. Settings uses `SettingsLink` on macOS 14+
// (the only reliable way to open Settings from an LSUIElement app);
// macOS 13 falls through to controller.openSettings().
import SwiftUI

public struct FooterBar: View {
    public let updates: UpdateController
    public let onSettings: () -> Void
    public let onWhatsNew: () -> Void
    public let onRestartDaemon: () -> Void
    public let onOpenLogs: () -> Void

    public init(
        updates: UpdateController,
        onSettings: @escaping () -> Void,
        onWhatsNew: @escaping () -> Void,
        onRestartDaemon: @escaping () -> Void,
        onOpenLogs: @escaping () -> Void
    ) {
        self.updates = updates
        self.onSettings = onSettings
        self.onWhatsNew = onWhatsNew
        self.onRestartDaemon = onRestartDaemon
        self.onOpenLogs = onOpenLogs
    }

    public var body: some View {
        VStack(spacing: 2) {
            // Primary row (icons left to right). SettingsLink can only
            // ride inside a Button label in macOS 14+, so we render the
            // settings entry conditionally.
            HStack(spacing: 4) {
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        FooterIcon(systemImage: "gearshape", label: "Settings")
                    }
                    .buttonStyle(FooterIconButtonStyle())
                } else {
                    FooterIconButton(
                        systemImage: "gearshape",
                        label: "Settings",
                        action: onSettings
                    )
                }
                FooterIconButton(systemImage: "sparkles", label: "What's New", action: onWhatsNew)
                CheckForUpdatesIconButton(updates: updates)
                FooterIconButton(systemImage: "arrow.clockwise", label: "Restart Daemon", action: onRestartDaemon)
                FooterIconButton(systemImage: "doc.text.magnifyingglass", label: "Open Logs", action: onOpenLogs)
                FooterIconButton(
                    systemImage: "power",
                    label: "Quit Myna",
                    action: { NSApplication.shared.terminate(nil) }
                )
            }
        }
    }
}

/// Small icon-only square button used inside the footer. Tooltip shows
/// the human label.
private struct FooterIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PopoverDesign.bodyColor.opacity(isHovering ? 1.0 : 0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .help(label)
            .accessibilityLabel(label)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in isHovering = hovering }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in
                        if isPressed { action() }
                        isPressed = false
                    }
            )
    }

    private var fillColor: Color {
        if isPressed { return PopoverDesign.pressedFill }
        if isHovering { return PopoverDesign.hoverFill }
        return Color.clear
    }
}

/// Stylised SwiftUI representation of the `SettingsLink` content so the
/// system Settings binding stays intact (macOS 14+). We just supply the
/// label; `.buttonStyle(FooterIconButtonStyle())` paints the hover state.
private struct FooterIcon: View {
    let systemImage: String
    let label: String
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .accessibilityLabel(label)
            .help(label)
    }
}

private struct FooterIconButtonStyle: ButtonStyle {
    @State private var isHovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(PopoverDesign.bodyColor.opacity(isHovering ? 1.0 : 0.7))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
            )
            .onHover { hovering in isHovering = hovering }
    }

    private func fillColor(pressed: Bool) -> Color {
        if pressed { return PopoverDesign.pressedFill }
        if isHovering { return PopoverDesign.hoverFill }
        return Color.clear
    }
}

/// "Check for Updates" footer button. Disables itself while Sparkle is
/// busy — matches what the old menu's CheckForUpdatesMenuItem did.
private struct CheckForUpdatesIconButton: View {
    @ObservedObject var updates: UpdateController

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: "square.and.arrow.down")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                PopoverDesign.bodyColor
                    .opacity(updates.canCheckForUpdates ? (isHovering ? 1.0 : 0.7) : 0.3)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .help("Check for Updates…")
            .accessibilityLabel("Check for Updates")
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                guard updates.canCheckForUpdates else { return }
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if updates.canCheckForUpdates { isPressed = true }
                    }
                    .onEnded { _ in
                        if isPressed && updates.canCheckForUpdates {
                            updates.checkForUpdates()
                        }
                        isPressed = false
                    }
            )
    }

    private var fillColor: Color {
        if !updates.canCheckForUpdates { return Color.clear }
        if isPressed { return PopoverDesign.pressedFill }
        if isHovering { return PopoverDesign.hoverFill }
        return Color.clear
    }
}
