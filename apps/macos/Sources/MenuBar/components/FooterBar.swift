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
                // Labels here are tuned to fit the 360pt popover across
                // six columns at the 9pt caption size. "Restart" / "Logs"
                // / "Quit" are the shortest unambiguous strings; the
                // tooltip (`.help`) and accessibilityLabel keep the long
                // form for screen-readers and hover-to-confirm.
                FooterIconButton(
                    systemImage: "arrow.clockwise",
                    label: "Restart",
                    longLabel: "Restart Daemon",
                    action: onRestartDaemon
                )
                FooterIconButton(
                    systemImage: "doc.text.magnifyingglass",
                    label: "Logs",
                    longLabel: "Open Logs",
                    action: onOpenLogs
                )
                FooterIconButton(
                    systemImage: "power",
                    label: "Quit",
                    longLabel: "Quit Myna",
                    action: { NSApplication.shared.terminate(nil) }
                )
            }
        }
    }
}

/// Compact icon-plus-label square used inside the footer. The label sits
/// directly under the icon so each button still occupies a narrow column —
/// six of them fit across the 360pt popover without wrapping. Tooltip
/// and a11y label show the full action ("Restart Daemon") even when the
/// visible caption is shortened to fit ("Restart").
private struct FooterIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    /// Full description for the tooltip + VoiceOver. Falls back to `label`.
    let longLabel: String?

    @State private var isHovering = false
    @State private var isPressed = false

    init(
        systemImage: String,
        label: String,
        longLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.longLabel = longLabel
        self.action = action
    }

    var body: some View {
        FooterIconLabel(systemImage: systemImage, label: label, isEnabled: true, isHovering: isHovering)
            .frame(maxWidth: .infinity)
            .frame(height: FooterMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .help(longLabel ?? label)
            .accessibilityLabel(longLabel ?? label)
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

/// Shared metrics so SettingsLink (which cannot host a Button without a
/// click intercept) and our gesture-based buttons render at the same
/// height. The label tagline keeps the popover from looking taller — we
/// use a small caption so the row stays under 44pt total.
private enum FooterMetrics {
    static let buttonHeight: CGFloat = 40
    static let iconSize: CGFloat = 12
    static let labelFont: Font = .system(size: 9, weight: .medium)
}

/// Vertical icon-plus-text used inside every footer entry. Pulled out so
/// the `SettingsLink` path (which can't intercept Button's `action`) and
/// the gesture path (which can) share one visual.
private struct FooterIconLabel: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let isHovering: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: FooterMetrics.iconSize, weight: .medium))
                .foregroundStyle(
                    PopoverDesign.bodyColor
                        .opacity(isEnabled ? (isHovering ? 1.0 : 0.7) : 0.3)
                )
            Text(label)
                .font(FooterMetrics.labelFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    PopoverDesign.secondaryColor
                        .opacity(isEnabled ? (isHovering ? 1.0 : 0.85) : 0.3)
                )
        }
        .padding(.horizontal, 2)
    }
}

/// Stylised SwiftUI representation of the `SettingsLink` content so the
/// system Settings binding stays intact (macOS 14+). We just supply the
/// label; `.buttonStyle(FooterIconButtonStyle())` paints the hover state.
private struct FooterIcon: View {
    let systemImage: String
    let label: String
    var body: some View {
        // SettingsLink's button-style modifier owns the hover/pressed
        // tinting; we just render the static icon+label stack here. The
        // tint flows through via foregroundStyle in the button style.
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: FooterMetrics.iconSize, weight: .medium))
            Text(label)
                .font(FooterMetrics.labelFont)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: FooterMetrics.buttonHeight)
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
        FooterIconLabel(
            systemImage: "square.and.arrow.down",
            label: "Updates",
            isEnabled: updates.canCheckForUpdates,
            isHovering: isHovering
        )
        .frame(maxWidth: .infinity)
        .frame(height: FooterMetrics.buttonHeight)
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
