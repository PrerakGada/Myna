// QuickActions.swift — the row that turned the popover from a readout
// into a menu.
//
// Before this, the only thing the popover could start was a replay of
// something already in Recent. Every actual read had to begin with a
// global hotkey, and the idle hero's job was to tell you which one. A
// menu-bar menu whose answer to "do the thing" is "press a key instead"
// is a readout with a chevron.
//
// The three actions here are the ones that survive the popover being
// open. That constraint is the whole design:
//
//   • Read clipboard  — the pasteboard doesn't care who is frontmost.
//   • Summarize       — same text, summary mode (the ⌥⇧⌘A path).
//   • Chrome tab      — asks Chrome over AppleEvents, not the focused app.
//
// "Read selection" is deliberately absent. SelectionService captures with
// a synthetic ⌘C aimed at the frontmost application, and opening this
// popover makes Myna frontmost — so the button would reliably read Myna's
// own window. It stays a hotkey, and `ReadyHint` shows the chord.
import SwiftUI

public struct QuickActions: View {
    /// Current clipboard text, or nil when there's nothing readable.
    /// Passed in (rather than probed here) so the whole row re-evaluates
    /// once per render instead of three times.
    public let clipboard: String?
    /// Disables everything while the engine is down — pressing a read
    /// action then would spin and fail.
    public let isEnabled: Bool
    public let onReadClipboard: () -> Void
    public let onSummarizeClipboard: () -> Void
    public let onReadChrome: () -> Void

    public init(
        clipboard: String?,
        isEnabled: Bool = true,
        onReadClipboard: @escaping () -> Void,
        onSummarizeClipboard: @escaping () -> Void,
        onReadChrome: @escaping () -> Void
    ) {
        self.clipboard = clipboard
        self.isEnabled = isEnabled
        self.onReadClipboard = onReadClipboard
        self.onSummarizeClipboard = onSummarizeClipboard
        self.onReadChrome = onReadChrome
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ActionTile(
                    systemImage: "doc.on.clipboard",
                    title: "Read clipboard",
                    emphasised: true,
                    isEnabled: isEnabled && clipboard != nil,
                    help: clipboardHelp,
                    action: onReadClipboard
                )
                ActionTile(
                    systemImage: "text.badge.minus",
                    title: "Summarize",
                    isEnabled: isEnabled && clipboard != nil,
                    help: "Summarize the clipboard, then read the summary",
                    action: onSummarizeClipboard
                )
                ActionTile(
                    systemImage: "globe",
                    title: "Chrome tab",
                    isEnabled: isEnabled,
                    help: "Read the article in Chrome's front tab",
                    action: onReadChrome
                )
            }
            clipboardLine
        }
    }

    /// One line under the tiles saying what "the clipboard" currently is.
    /// Without it, "Read clipboard" is a button you have to press to find
    /// out what it does.
    @ViewBuilder
    private var clipboardLine: some View {
        if let clipboard {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(PopoverDesign.secondaryColor)
                Text(ClipboardProbe.preview(clipboard))
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(ClipboardProbe.durationLabel(clipboard))
                    .font(PopoverDesign.timeCodeFont)
                    .foregroundStyle(PopoverDesign.secondaryColor.opacity(0.8))
            }
            .padding(.horizontal, 2)
        } else {
            Text("Clipboard is empty — copy some text to read it here.")
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.disabledColor)
                .padding(.horizontal, 2)
        }
    }

    private var clipboardHelp: String {
        guard let clipboard else { return "Nothing on the clipboard" }
        return "Read \(ClipboardProbe.durationLabel(clipboard)) from the clipboard"
    }
}

/// One tile in the quick-action row. Glyph over label, hover lift, and a
/// disabled state that stays legible instead of vanishing.
///
/// Gesture rather than `Button` for the same reason as everything else in
/// this popover: `.plain` still flashes a system tint on click, which looks
/// wrong on the near-black surface (see HoverableRow's note).
private struct ActionTile: View {
    let systemImage: String
    let title: String
    var emphasised: Bool = false
    let isEnabled: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(glyphColor)
            Text(title)
                .font(.system(size: 10, weight: emphasised ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(labelColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PopoverDesign.actionTileHeight)
        .background(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .contentShape(RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous))
        .onHover { hovering in
            guard isEnabled else { return }
            isHovering = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled { isPressed = true } }
                .onEnded { _ in
                    if isPressed && isEnabled { action() }
                    isPressed = false
                }
        )
    }

    private var glyphColor: Color {
        guard isEnabled else { return PopoverDesign.disabledColor }
        if emphasised { return PopoverDesign.accent }
        return PopoverDesign.bodyColor.opacity(isHovering ? 1.0 : 0.85)
    }

    private var labelColor: Color {
        guard isEnabled else { return PopoverDesign.disabledColor }
        return emphasised
            ? PopoverDesign.bodyColor
            : PopoverDesign.secondaryColor.opacity(isHovering ? 1.0 : 0.9)
    }

    private var fillColor: Color {
        guard isEnabled else { return Color.white.opacity(0.02) }
        if isPressed { return PopoverDesign.pressedFill }
        if emphasised {
            return isHovering
                ? PopoverDesign.primaryActionHoverFill
                : PopoverDesign.primaryActionFill
        }
        return isHovering ? PopoverDesign.actionHoverFill : PopoverDesign.actionFill
    }

    private var borderColor: Color {
        guard isEnabled else { return Color.clear }
        return emphasised ? PopoverDesign.primaryActionBorder : PopoverDesign.cardBorder
    }
}

/// One-line reminder of the selection hotkey, shown when nothing is
/// playing. This is all that survives of the old 130pt IdleHero card,
/// which spent a third of the popover to say "No audio playing" and then
/// name a keyboard shortcut.
public struct ReadyHint: View {
    public let speakHotkey: String?
    public let summaryHotkey: String?

    public init(speakHotkey: String?, summaryHotkey: String? = nil) {
        self.speakHotkey = speakHotkey
        self.summaryHotkey = summaryHotkey
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.cursor")
                .font(.system(size: 8))
                .foregroundStyle(PopoverDesign.secondaryColor)
            Text(hint)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var hint: String {
        guard let speakHotkey else {
            return "Select text in any app, then use the read-aloud shortcut."
        }
        return "Select text in any app and press \(speakHotkey) to read it."
    }
}

/// Amber strip for "the daemon is up but its voice engine isn't".
///
/// This case had no popover representation at all: `IconStateMapping`
/// turns engine-down into a red bird, but `PopoverModelBuilder` only ever
/// looked at reachability — so the menu bar went red while the popover
/// said READY. It's a warning rather than an error hero because audio
/// already buffered keeps playing while the engine restarts.
public struct EngineWarningStrip: View {
    public let onRestart: () -> Void

    public init(onRestart: @escaping () -> Void) {
        self.onRestart = onRestart
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(PopoverDesign.warning)
            Text("Voice engine is down — new reads will fail.")
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.bodyColor.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onRestart) {
                Text("Restart")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(PopoverDesign.warning.opacity(0.22)))
                    .foregroundStyle(PopoverDesign.warning)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Restart the voice engine")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .fill(PopoverDesign.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .strokeBorder(PopoverDesign.warning.opacity(0.28), lineWidth: 1)
        )
    }
}
