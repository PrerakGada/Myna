// IdleHero.swift — empty-state hero card shown when no audio is playing.
// Walks the user toward the speak-selection shortcut so the menu bar
// doesn't feel "dead" on launch.
//
// Same outer chrome as NowPlayingCard so the popover doesn't shift
// height when state flips between idle and playing.
import SwiftUI

public struct IdleHero: View {
    /// Hotkey for the primary "speak selection" shortcut, rendered into
    /// the hint string. Nil → text-only hint, no glyph cluster.
    public let speakHotkey: String?

    public init(speakHotkey: String? = nil) {
        self.speakHotkey = speakHotkey
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(PopoverDesign.dotIdle)
                    .frame(width: 6, height: 6)
                Text("READY")
                    .font(PopoverDesign.sectionHeaderFont)
                    .tracking(0.5)
                    .foregroundStyle(PopoverDesign.sectionHeaderColor)
            }
            Text("No audio playing")
                .font(PopoverDesign.heroTitleFont)
                .foregroundStyle(PopoverDesign.bodyColor)
            Text(hintText)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopoverDesign.cardInteriorPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .fill(PopoverDesign.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .strokeBorder(PopoverDesign.cardBorder, lineWidth: 1)
        )
    }

    private var hintText: String {
        if let speakHotkey {
            return "Select text anywhere and press \(speakHotkey) to read it aloud."
        }
        return "Select text anywhere and trigger the read-aloud shortcut to begin."
    }
}

/// Error-state hero. Shares the chrome with NowPlayingCard/IdleHero so
/// the popover doesn't jump height when the daemon goes down.
public struct ErrorHero: View {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(PopoverDesign.dotError)
                    .frame(width: 6, height: 6)
                Text("ATTENTION")
                    .font(PopoverDesign.sectionHeaderFont)
                    .tracking(0.5)
                    .foregroundStyle(PopoverDesign.sectionHeaderColor)
            }
            Text("Daemon unreachable")
                .font(PopoverDesign.heroTitleFont)
                .foregroundStyle(PopoverDesign.bodyColor)
            Text(message)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.dotError.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PopoverDesign.cardInteriorPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .fill(PopoverDesign.dotError.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .strokeBorder(PopoverDesign.dotError.opacity(0.25), lineWidth: 1)
        )
    }
}
