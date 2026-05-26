// SectionHeader.swift — disclosure-style row that toggles a section open
// or closed. Per the v0.2.1 redesign brief, we replace NSMenu submenus
// (which collapse on every poll rebuild) with these SwiftUI sections —
// the open/closed state is owned by SwiftUI @State, so polling refreshes
// don't disturb it.
//
// Visual: all-caps section title left, optional trailing badge / value,
// chevron right. Hover lights the background.
import SwiftUI

public struct SectionHeader: View {
    public let title: String
    /// Optional trailing label (e.g. "1.2×" for the SPEED row showing
    /// current value at-a-glance, or "(2)" for the CC count badge).
    public let trailing: String?
    /// Optional color for the trailing badge. Defaults to secondary.
    public let trailingColor: Color
    @Binding public var isExpanded: Bool

    public init(
        title: String,
        trailing: String? = nil,
        trailingColor: Color = PopoverDesign.secondaryColor,
        isExpanded: Binding<Bool>
    ) {
        self.title = title
        self.trailing = trailing
        self.trailingColor = trailingColor
        self._isExpanded = isExpanded
    }

    public var body: some View {
        HoverableRow(
            cornerRadius: 6,
            horizontalPadding: 8,
            verticalPadding: 6,
            action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            },
            content: {
                HStack(spacing: 8) {
                    Text(title.uppercased())
                        .font(PopoverDesign.sectionHeaderFont)
                        .tracking(0.5)
                        .foregroundStyle(PopoverDesign.sectionHeaderColor)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing)
                            .font(PopoverDesign.captionFont)
                            .foregroundStyle(trailingColor)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PopoverDesign.secondaryColor)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
            }
        )
    }
}
