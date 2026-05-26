// HoverableRow.swift — shared hover background for clickable popover
// rows / pills. SwiftUI's default Button styles fight the popover
// aesthetic (system blue pill on hover, weird vertical padding), so
// every clickable surface in the popover wraps content in `.hoverable()`
// and an explicit `.contentShape` + tap gesture instead of `Button`.
//
// Why not `.buttonStyle(.plain)`?  `.plain` keeps the title intact but
// still applies a momentary blue tint on click that flashes weird
// against our dark surface. Doing the gesture ourselves avoids it.
import SwiftUI

/// Hover-aware wrapper. Used by SectionHeader, FooterBar buttons, voice
/// tiles, recent rows, etc.
public struct HoverableRow<Content: View>: View {
    private let cornerRadius: CGFloat
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let onTap: () -> Void
    private let content: Content
    private let isDisabled: Bool

    @State private var isHovering = false
    @State private var isPressed = false

    public init(
        cornerRadius: CGFloat = 6,
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 6,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.isDisabled = isDisabled
        self.onTap = action
        self.content = content()
    }

    public var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(backgroundFill)
            .opacity(isDisabled ? 0.4 : 1.0)
            .onHover { hovering in
                guard !isDisabled else { return }
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDisabled { isPressed = true }
                    }
                    .onEnded { _ in
                        if isPressed && !isDisabled {
                            onTap()
                        }
                        isPressed = false
                    }
            )
    }

    private var backgroundFill: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fillColor)
    }

    private var fillColor: Color {
        if isDisabled { return Color.clear }
        if isPressed { return PopoverDesign.pressedFill }
        if isHovering { return PopoverDesign.hoverFill }
        return Color.clear
    }
}
