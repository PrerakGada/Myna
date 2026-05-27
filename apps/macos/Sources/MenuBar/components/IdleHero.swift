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

/// Loading-state hero. Shown after the user triggers speak but before
/// the first audio chunk lands. Shares chrome with IdleHero / NowPlayingCard
/// so the popover doesn't jump in height during the transition.
///
/// Visual: amber dot + "PROCESSING" eyebrow + "Synthesizing speech…" +
/// truncated preview text (if known) + a low-key indeterminate
/// ProgressView. The ProgressView's circular indeterminate spinner is
/// the only one in the menu bar UI — it's GPU-driven so the v0.2.1
/// CPU-bug fix's no-`TimelineView` rule isn't violated.
public struct LoadingHero: View {
    public let previewTitle: String?

    public init(previewTitle: String? = nil) {
        self.previewTitle = previewTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(PopoverDesign.dotThinking)
                    .frame(width: 6, height: 6)
                Text("PROCESSING")
                    .font(PopoverDesign.sectionHeaderFont)
                    .tracking(0.5)
                    .foregroundStyle(PopoverDesign.sectionHeaderColor)
            }
            HStack(spacing: 10) {
                Text("Synthesizing speech…")
                    .font(PopoverDesign.heroTitleFont)
                    .foregroundStyle(PopoverDesign.bodyColor)
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(PopoverDesign.dotThinking)
            }
            if let previewTitle, !previewTitle.isEmpty {
                Text(previewTitle)
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Daemon is preparing the first chunk.")
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
            }
        }
        .padding(PopoverDesign.cardInteriorPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .fill(PopoverDesign.dotThinking.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
                .strokeBorder(PopoverDesign.dotThinking.opacity(0.25), lineWidth: 1)
        )
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
