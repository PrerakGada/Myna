// FeedbackRow.swift — "Report a Problem…" and "Send Feedback…" side by side
// in the popover. Both open the same feedback window, preselecting Problem or
// Idea. The footer's six columns are full, so this rides above it like the
// "Reset pill position" row.
import SwiftUI

struct FeedbackRow: View {
    var body: some View {
        HStack(spacing: 4) {
            item(systemImage: "exclamationmark.bubble", title: "Report a Problem…", kind: .problem)
            item(systemImage: "text.bubble", title: "Send Feedback…", kind: .idea)
        }
    }

    private func item(systemImage: String, title: String, kind: FeedbackKind) -> some View {
        HoverableRow(
            cornerRadius: 6,
            horizontalPadding: 8,
            verticalPadding: 6,
            action: { FeedbackLauncher.shared.present(kind: kind) },
            content: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PopoverDesign.bodyColor.opacity(0.8))
                    Text(title)
                        .font(PopoverDesign.bodyFont)
                        .foregroundStyle(PopoverDesign.bodyColor)
                        .lineLimit(1)
                }
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}
