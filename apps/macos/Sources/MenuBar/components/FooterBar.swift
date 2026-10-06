// FooterBar.swift — bottom row of the popover: Myna · What's New ·
// Check for Updates · Quit.
//
// It used to be six. Restart Daemon and Open Logs sat here at the same
// visual weight as Settings and Quit, which made the footer read as a
// flat list of six equally-likely things to do — and squeezed every
// caption to 9pt across a 360pt popover, so "Restart Daemon" had to be
// truncated to "Restart" and "Open Logs" to "Logs". Both are recovery
// actions, not daily ones, so they moved into OPTIONS ▸ Troubleshooting.
//
// They did not get harder to reach when it matters: the moment the daemon
// or the engine actually falls over, ErrorHero and EngineWarningStrip put
// a Restart button directly in front of the user.
//
// The first column used to be Settings, opening the seven-tab Settings
// scene through `SettingsLink` — the one reliable way to open it from an
// LSUIElement app, and still awkward (see SettingsWindowActivator for the
// activation dance it needed). It now opens the Dashboard: a real window
// that carries those same preferences plus the reading history and its
// analytics. The Settings scene stays registered so ⌘, keeps working, but
// nothing in the UI points at it any more.
import SwiftUI

public struct FooterBar: View {
    public let updates: UpdateController
    public let onDashboard: () -> Void
    public let onWhatsNew: () -> Void

    public init(
        updates: UpdateController,
        onDashboard: @escaping () -> Void,
        onWhatsNew: @escaping () -> Void
    ) {
        self.updates = updates
        self.onDashboard = onDashboard
        self.onWhatsNew = onWhatsNew
    }

    public var body: some View {
        VStack(spacing: 2) {
            // Primary row, icons left to right.
            HStack(spacing: 4) {
                FooterIconButton(
                    systemImage: "square.grid.2x2",
                    label: "Myna",
                    longLabel: "Open the Myna window — history, stats and every setting",
                    action: onDashboard
                )
                // Four columns at 360pt means each caption gets ~83pt, so
                // every label fits at its full length. That is the whole
                // reason the diagnostics moved out.
                FooterIconButton(systemImage: "sparkles", label: "What's New", action: onWhatsNew)
                CheckForUpdatesIconButton(updates: updates)
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
/// directly under the icon so each button occupies a narrow column. The
/// tooltip and a11y label carry the full action even when the visible
/// caption is shortened to fit ("Myna" → "Open the Myna window…").
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

/// Shared metrics so every footer column renders at the same height. The
/// caption sits under the icon in a small size so the row stays under 44pt
/// total and the popover doesn't grow.
private enum FooterMetrics {
    static let buttonHeight: CGFloat = 38
    static let iconSize: CGFloat = 13
    /// 10pt rather than 9pt — four columns leave room for a caption you
    /// can actually read at a glance.
    static let labelFont: Font = .system(size: 10, weight: .medium)
}

/// Vertical icon-plus-text used inside every footer entry.
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
