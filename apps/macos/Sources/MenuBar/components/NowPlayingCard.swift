// NowPlayingCard.swift — hero card at the top of the popover when Myna
// is actively reading something. Shows the title, voice/speed metadata,
// a progress bar, and a transport button row.
//
// State is read straight from PopoverModel — same data the menu shipped
// in v0.2.0; only the rendering changes. Tests live in
// PopoverModelTests.
import SwiftUI

public struct NowPlayingCard: View {
    public let nowReading: PopoverModel.NowReading
    public let isPaused: Bool
    public let pauseHotkey: String?
    public let stopHotkey: String?
    public let onTogglePause: () -> Void
    public let onStop: () -> Void
    public let onSkipBack: () -> Void
    public let onSkipForward: () -> Void

    public init(
        nowReading: PopoverModel.NowReading,
        isPaused: Bool,
        pauseHotkey: String? = nil,
        stopHotkey: String? = nil,
        onTogglePause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSkipBack: @escaping () -> Void,
        onSkipForward: @escaping () -> Void
    ) {
        self.nowReading = nowReading
        self.isPaused = isPaused
        self.pauseHotkey = pauseHotkey
        self.stopHotkey = stopHotkey
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        self.onSkipBack = onSkipBack
        self.onSkipForward = onSkipForward
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Eyebrow: "NOW PLAYING" or "PAUSED"
            HStack(spacing: 6) {
                Circle()
                    .fill(isPaused ? PopoverDesign.dotPaused : PopoverDesign.dotSpeaking)
                    .frame(width: 6, height: 6)
                Text(isPaused ? "PAUSED" : "NOW PLAYING")
                    .font(PopoverDesign.sectionHeaderFont)
                    .tracking(0.5)
                    .foregroundStyle(PopoverDesign.sectionHeaderColor)
            }
            // Title
            Text(nowReading.truncatedTitle)
                .font(PopoverDesign.heroTitleFont)
                .foregroundStyle(PopoverDesign.bodyColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            // Metadata line
            Text(nowReading.formattedMetadata)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.secondaryColor)
            // Progress bar
            progressBar
            // Transport row
            transportRow
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

    private var progressBar: some View {
        GeometryReader { geom in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 3)
                Capsule()
                    .fill(PopoverDesign.accent)
                    .frame(width: geom.size.width * CGFloat(progressFraction), height: 3)
            }
        }
        .frame(height: 3)
    }

    private var progressFraction: Double {
        let dur = nowReading.durationSeconds
        guard dur > 0 else { return 0 }
        return min(1.0, max(0.0, nowReading.positionSeconds / dur))
    }

    private var transportRow: some View {
        HStack(spacing: 6) {
            transportButton(
                systemImage: "gobackward.15",
                label: "Back 15s",
                a11yLabel: "Skip back 15 seconds",
                action: onSkipBack
            )
            transportButton(
                systemImage: isPaused ? "play.fill" : "pause.fill",
                label: isPaused ? "Resume" : "Pause",
                hotkey: pauseHotkey,
                emphasised: true,
                action: onTogglePause
            )
            transportButton(
                systemImage: "stop.fill",
                label: "Stop",
                hotkey: stopHotkey,
                action: onStop
            )
            transportButton(
                systemImage: "goforward.15",
                label: "Skip 15s",
                a11yLabel: "Skip forward 15 seconds",
                action: onSkipForward
            )
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func transportButton(
        systemImage: String,
        label: String,
        a11yLabel: String? = nil,
        hotkey: String? = nil,
        emphasised: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        TransportButton(
            systemImage: systemImage,
            label: label,
            a11yLabel: a11yLabel ?? label,
            hotkey: hotkey,
            emphasised: emphasised,
            action: action
        )
    }
}

/// Single transport button. Pulled out so hover state stays local to
/// each button. The label sits under the icon at caption size so users
/// can identify each control without relying on the tooltip.
private struct TransportButton: View {
    let systemImage: String
    let label: String
    /// Longer description used for the tooltip + VoiceOver (e.g. "Skip
    /// back 15 seconds" while the visible label is shortened to fit).
    let a11yLabel: String
    let hotkey: String?
    let emphasised: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fillColor)
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: emphasised ? 15 : 13, weight: .semibold))
                    .foregroundStyle(PopoverDesign.bodyColor)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(PopoverDesign.secondaryColor)
            }
        }
        .frame(maxWidth: .infinity)
        // Slightly taller now that we host a caption row underneath
        // the glyph. Still under the popover's 360pt outer footprint.
        .frame(height: emphasised ? 44 : 40)
        .help(helpString)
        .accessibilityLabel(a11yLabel)
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
        if isHovering {
            return emphasised
                ? PopoverDesign.accent.opacity(0.25)
                : PopoverDesign.hoverFill
        }
        return emphasised ? PopoverDesign.accent.opacity(0.15) : Color.white.opacity(0.04)
    }

    private var helpString: String {
        if let hotkey { return "\(a11yLabel) (\(hotkey))" }
        return a11yLabel
    }
}
