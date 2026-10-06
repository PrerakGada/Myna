// OptionsSection.swift — the settings you actually flip, in the place you
// actually are.
//
// Everything in here already existed; all of it lived behind a seven-tab
// Settings window that an accessory app opens awkwardly (see
// SettingsWindowActivator for how awkwardly). Toggling "show the floating
// pill" meant: click the bird, click Settings, wait for the window to come
// forward, find Advanced, toggle, close. Five steps for a switch.
//
// The full Settings window keeps everything — voice previews with ducking,
// the hotkey recorders, daemon URLs, the Voice Wardrobe, log levels, reset.
// This group carries only the toggles with day-to-day reasons to change,
// and links out for the rest. If a control needs explanation longer than
// its own label, it belongs in Settings, not here.
import AppKit
import SwiftUI

public struct OptionsSection: View {
    @ObservedObject var settings: SettingsViewModel

    /// The floating pill's master switch. Read as raw defaults rather than
    /// through SettingsViewModel because the FloatingPill module owns this
    /// key directly and deliberately has no dependency on the view model.
    @AppStorage(PillController.enabledDefaultsKey) private var showFloatingPill: Bool = true

    public let onRestartDaemon: () -> Void
    public let onOpenLogs: () -> Void
    public let onOpenSettings: () -> Void

    public init(
        settings: SettingsViewModel,
        onRestartDaemon: @escaping () -> Void,
        onOpenLogs: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.settings = settings
        self.onRestartDaemon = onRestartDaemon
        self.onOpenLogs = onOpenLogs
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Reading") {
                OptionToggle(
                    label: "Buffer before playing",
                    help: "Collect a few seconds of audio before starting, so long "
                        + "reads never stall mid-sentence. Off starts sooner.",
                    isOn: $settings.oneShotPlayback
                )
            }
            group("Floating pill") {
                OptionToggle(
                    label: "Show while speaking",
                    help: "A small chip at the bottom of your active display while Myna reads.",
                    isOn: $showFloatingPill
                )
                OptionToggle(
                    label: "Keep it always visible",
                    help: "Leave the chip on screen even when nothing is playing. Drag it anywhere.",
                    isOn: $settings.pillAlwaysVisible,
                    isEnabled: showFloatingPill
                )
                if showFloatingPill {
                    OptionAction(
                        systemImage: "arrow.uturn.left.circle",
                        label: "Reset pill position",
                        help: "Snap the pill back to the bottom-centre of the screen under your cursor.",
                        action: {
                            NotificationCenter.default.post(
                                name: PillController.resetPositionNotification,
                                object: nil
                            )
                        }
                    )
                }
            }
            group("Claude Code") {
                OptionToggle(
                    label: "Announce finished sessions",
                    help: "When a Claude Code session finishes, offer its reply for playback.",
                    isOn: $settings.ccToastsEnabled
                )
                OptionToggle(
                    label: "Chime on new reply",
                    help: "A short tick when a Claude Code card appears.",
                    isOn: $settings.toastChimeEnabled,
                    isEnabled: settings.ccToastsEnabled
                )
                OptionToggle(
                    label: "Read only the bold claims",
                    help: "Play just the bold sentences of a reply. "
                        + "A reply with no bold is read in full.",
                    isOn: $settings.ccBoldClaimsOnly,
                    isEnabled: settings.ccToastsEnabled
                )
            }
            group("Trackpad & sound") {
                OptionToggle(
                    label: "Trackpad gestures",
                    help: "Four-finger gestures for play, pause and skip.",
                    isOn: $settings.trackpadGesturesEnabled
                )
                OptionToggle(
                    label: "Tone when a gesture lands",
                    help: "A 55ms rising tone the moment a gesture registers, so silence "
                        + "doesn't read as a missed gesture.",
                    isOn: $settings.gestureEarconEnabled,
                    isEnabled: settings.trackpadGesturesEnabled
                )
            }
            group("Troubleshooting") {
                OptionAction(
                    systemImage: "arrow.clockwise",
                    label: "Restart voice engine",
                    help: "Kickstart the launchd job that runs the Myna daemon.",
                    action: onRestartDaemon
                )
                OptionAction(
                    systemImage: "doc.text.magnifyingglass",
                    label: "Open logs",
                    help: "Reveal today's log file in Finder.",
                    action: onOpenLogs
                )
                OptionAction(
                    systemImage: "square.grid.2x2",
                    label: "Open Myna…",
                    help: "The full window: reading history and stats, hotkeys, voice previews, "
                        + "app voices, engine health and logs.",
                    action: onOpenSettings
                )
            }
        }
        .padding(.leading, PopoverDesign.nestedIndent)
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(PopoverDesign.sectionHeaderColor.opacity(0.75))
                .padding(.bottom, 2)
            content()
        }
    }
}

/// A label plus a system switch, sized so a column of them stays compact.
/// Disabled rows stay visible (dimmed) rather than disappearing — a
/// dependent switch that vanishes when its parent turns off teaches the
/// user nothing about why.
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(PopoverDesign.bodyFont)
                .foregroundStyle(isEnabled ? PopoverDesign.bodyColor : PopoverDesign.disabledColor)
                .lineLimit(1)
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!isEnabled)
                // The popover's window is never key, so AppKit's own
                // disabled styling doesn't reliably come through — a
                // switch you can't touch was painting at full accent blue.
                .opacity(isEnabled ? 1.0 : 0.45)
        }
        .frame(height: PopoverDesign.optionRowHeight)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }
}

/// A one-shot action styled to sit in the same column as the toggles.
private struct OptionAction: View {
    let systemImage: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        HoverableRow(
            cornerRadius: 5,
            horizontalPadding: 6,
            verticalPadding: 4,
            action: action,
            content: {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PopoverDesign.secondaryColor)
                        .frame(width: 13)
                    Text(label)
                        .font(PopoverDesign.bodyFont)
                        .foregroundStyle(PopoverDesign.bodyColor)
                    Spacer(minLength: 0)
                }
            }
        )
        .padding(.horizontal, -6)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(help)
    }
}
