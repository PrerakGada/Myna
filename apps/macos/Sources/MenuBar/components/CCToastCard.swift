// CCToastCard.swift — single Claude Code pending item in the popover
// CLAUDE CODE section. Visual: colored dot from the project palette,
// title, age, Play / Discard buttons.
//
// Color comes straight from ProjectPalette.color(for:) — same hue the
// floating CCToastWindow uses, so a user who's been seeing "blue" toasts
// from `myna-repo` instantly recognises them here too.
import SwiftUI

public struct CCToastCard: View {
    public let item: RegistryV2Item
    public let onPlay: () -> Void
    public let onDiscard: () -> Void

    public init(
        item: RegistryV2Item,
        onPlay: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.item = item
        self.onPlay = onPlay
        self.onDiscard = onDiscard
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(projectShortName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PopoverDesign.bodyColor)
                Text("·")
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
                Text(ageString)
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
                Spacer(minLength: 0)
            }
            Text(item.preview(maxLength: 60))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(PopoverDesign.bodyColor.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                actionButton(label: "Play", systemImage: "play.fill", emphasised: true, action: onPlay)
                actionButton(label: "Dismiss", systemImage: "xmark", emphasised: false, action: onDiscard)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(PopoverDesign.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(dotColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var dotColor: Color {
        Color(palette: ProjectPalette.color(for: item.projectId))
    }

    private var projectShortName: String {
        // Use the last path component (or the whole id if it's not
        // path-like). Cap at 22 chars so the row never breaks layout.
        let last = (item.projectId as NSString).lastPathComponent
        let base = last.isEmpty ? item.projectId : last
        if base.count <= 22 { return base }
        return String(base.prefix(22)) + "…"
    }

    private var ageString: String {
        let age = item.ageSeconds()
        if age < 30 { return "just now" }
        if age < 60 { return "\(age)s ago" }
        if age < 3_600 { return "\(age / 60)m ago" }
        if age < 86_400 { return "\(age / 3_600)h ago" }
        return "\(age / 86_400)d ago"
    }

    @ViewBuilder
    private func actionButton(
        label: String,
        systemImage: String,
        emphasised: Bool,
        action: @escaping () -> Void
    ) -> some View {
        CCActionPill(
            label: label,
            systemImage: systemImage,
            tint: emphasised ? dotColor : PopoverDesign.secondaryColor,
            emphasised: emphasised,
            action: action
        )
    }
}

private struct CCActionPill: View {
    let label: String
    let systemImage: String
    let tint: Color
    let emphasised: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(emphasised ? tint : PopoverDesign.bodyColor.opacity(0.85))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(emphasised ? tint.opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovering = $0 }
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
            return emphasised ? tint.opacity(0.25) : PopoverDesign.hoverFill
        }
        return emphasised ? tint.opacity(0.15) : Color.white.opacity(0.04)
    }
}
