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
    /// Nil for a section that is always open — the header then renders as a
    /// plain caption with no chevron and no click target. Added with the
    /// v0.6 rework, where SPEED stopped being a disclosure: one number
    /// behind a chevron is a click charged for nothing.
    private let expansion: Binding<Bool>?

    public init(
        title: String,
        trailing: String? = nil,
        trailingColor: Color = PopoverDesign.secondaryColor,
        isExpanded: Binding<Bool>
    ) {
        self.title = title
        self.trailing = trailing
        self.trailingColor = trailingColor
        self.expansion = isExpanded
    }

    /// Static header for an always-visible section.
    public init(
        title: String,
        trailing: String? = nil,
        trailingColor: Color = PopoverDesign.secondaryColor
    ) {
        self.title = title
        self.trailing = trailing
        self.trailingColor = trailingColor
        self.expansion = nil
    }

    public var body: some View {
        if let expansion {
            collapsible(expansion)
        } else {
            label(isExpanded: true, showChevron: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func label(isExpanded: Bool, showChevron: Bool) -> some View {
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
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PopoverDesign.secondaryColor)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
        }
    }

    @ViewBuilder
    private func collapsible(_ isExpanded: Binding<Bool>) -> some View {
        HoverableRow(
            cornerRadius: 6,
            horizontalPadding: 8,
            verticalPadding: 6,
            action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.wrappedValue.toggle()
                }
            },
            content: {
                label(isExpanded: isExpanded.wrappedValue, showChevron: true)
            }
        )
    }
}
