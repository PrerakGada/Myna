// RecentRow.swift — single row inside the RECENT section. Click to replay
// (controller posts `mynaReplayRecent` which AppDispatcher catches).
//
// Layout: bullet · title (truncated to 38) · trailing voice · age.
import SwiftUI

public struct RecentRow: View {
    public let item: RecentItem
    public let onSelect: () -> Void

    public init(item: RecentItem, onSelect: @escaping () -> Void) {
        self.item = item
        self.onSelect = onSelect
    }

    public var body: some View {
        HoverableRow(
            cornerRadius: 6,
            horizontalPadding: 8,
            verticalPadding: 6,
            action: onSelect,
            content: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PopoverDesign.secondaryColor)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.truncatedTitle())
                            .font(PopoverDesign.bodyFont)
                            .foregroundStyle(PopoverDesign.bodyColor)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(item.voice)
                                .foregroundStyle(PopoverDesign.secondaryColor)
                            Text("·")
                                .foregroundStyle(PopoverDesign.secondaryColor)
                            Text(item.ageString())
                                .foregroundStyle(PopoverDesign.secondaryColor)
                        }
                        .font(PopoverDesign.captionFont)
                    }
                    Spacer(minLength: 0)
                }
            }
        )
    }
}
