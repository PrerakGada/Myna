// StatusHeroes.swift — the two hero cards that still earn their height.
//
// Was IdleHero.swift. The idle hero itself is gone: it spent roughly a
// third of the popover drawing a bordered card that said "No audio
// playing" and then named a keyboard shortcut. Idle is now the quick-action
// row plus a one-line `ReadyHint` (see QuickActions.swift), so the space
// goes to controls instead of to a restatement of the status pill.
//
// What's left are the two states that genuinely need a card: something is
// being prepared, or something is wrong.
import SwiftUI

/// Loading-state hero. Shown after the user triggers speak but before
/// the first audio chunk lands.
///
/// Visual: amber dot + "PREPARING" eyebrow + truncated preview text (if
/// known) + a low-key indeterminate ProgressView. The ProgressView's
/// circular spinner is the only animation in the popover — it's GPU-driven,
/// so the v0.2.1 CPU-bug fix's no-`TimelineView` rule isn't violated.
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
                Text("PREPARING")
                    .font(PopoverDesign.sectionHeaderFont)
                    .tracking(0.5)
                    .foregroundStyle(PopoverDesign.sectionHeaderColor)
                Spacer(minLength: 0)
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(PopoverDesign.dotThinking)
            }
            if let previewTitle, !previewTitle.isEmpty {
                Text(previewTitle)
                    .font(PopoverDesign.heroTitleFont)
                    .foregroundStyle(PopoverDesign.bodyColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Synthesizing speech…")
                    .font(PopoverDesign.heroTitleFont)
                    .foregroundStyle(PopoverDesign.bodyColor)
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

/// Error-state hero — the daemon isn't answering at all.
///
/// Two ways out, because there are two causes. A fresh install that never
/// finished setup needs the installer; a daemon that died needs a restart.
/// Before this the card offered only "Set up Myna…", which is the wrong
/// and slightly alarming answer for a working install whose launchd job
/// happened to fall over.
public struct ErrorHero: View {
    public let message: String
    public let onSetup: (() -> Void)?
    public let onRestart: (() -> Void)?

    public init(
        message: String,
        onSetup: (() -> Void)? = nil,
        onRestart: (() -> Void)? = nil
    ) {
        self.message = message
        self.onSetup = onSetup
        self.onRestart = onRestart
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
            Text("Myna's voice isn't running")
                .font(PopoverDesign.heroTitleFont)
                .foregroundStyle(PopoverDesign.bodyColor)
            Text(message)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.dotError.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let onRestart {
                    Button(action: onRestart) {
                        pillLabel("Restart voice", filled: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Restart the voice engine")
                }
                if let onSetup {
                    Button(action: onSetup) {
                        pillLabel("Set up Myna…", filled: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the Myna installer")
                }
            }
            .padding(.top, 2)
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

    @ViewBuilder
    private func pillLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(filled ? PopoverDesign.accent : Color.white.opacity(0.08))
            )
            .foregroundStyle(filled ? Color.white : PopoverDesign.bodyColor)
    }
}
