// VoiceTile.swift — single voice in the expanded VOICE grid. Click the
// body to select; click the play glyph to preview.
//
// We keep voice previews out-of-process in the Settings tab (that's
// where the audio-duck logic lives). The tile's "▶" glyph is informational
// for v0.2.1 — wired through `onPreview` but defaults to a no-op when
// no preview service is supplied. Selecting via tap rewrites
// `settings.voice` like the old menu did.
import SwiftUI

public struct VoiceTile: View {
    public let voice: Voice
    public let isSelected: Bool
    public let onSelect: () -> Void
    public let onPreview: (() -> Void)?

    @State private var isHovering = false
    @State private var isPressed = false
    @State private var isPreviewHovering = false

    public init(
        voice: Voice,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onPreview: (() -> Void)? = nil
    ) {
        self.voice = voice
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onPreview = onPreview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                Text(displayLabel)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(PopoverDesign.bodyColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(PopoverDesign.accent)
                }
            }
            HStack {
                Text(voice.lang)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(PopoverDesign.secondaryColor)
                Spacer(minLength: 0)
                if onPreview != nil {
                    previewButton
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(bodyFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? PopoverDesign.accent.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in isHovering = hovering }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    if isPressed { onSelect() }
                    isPressed = false
                }
        )
    }

    private var displayLabel: String {
        // Voice.label is the human-readable name from the daemon; if
        // it ends up empty we degrade to the id so the user can still
        // tell them apart.
        voice.label.isEmpty ? voice.id : voice.label
    }

    private var bodyFill: Color {
        if isPressed { return PopoverDesign.pressedFill }
        if isHovering { return PopoverDesign.hoverFill }
        if isSelected { return PopoverDesign.accent.opacity(0.12) }
        return Color.white.opacity(0.04)
    }

    @ViewBuilder
    private var previewButton: some View {
        if let onPreview {
            HStack(spacing: 3) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 11, weight: .regular))
                Text("Preview")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(
                isPreviewHovering ? PopoverDesign.accent : PopoverDesign.secondaryColor
            )
            .contentShape(Rectangle())
            .onHover { isPreviewHovering = $0 }
            .onTapGesture { onPreview() }
            .help("Preview \(displayLabel)")
            .accessibilityLabel("Preview \(displayLabel)")
        }
    }
}
