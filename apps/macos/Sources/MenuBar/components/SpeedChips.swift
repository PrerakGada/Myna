// SpeedChips.swift — row of chips for the SPEED section. Click one to
// set the player speed. The selected chip stays accent-tinted.
//
// AVAudioUnitTimePitch's `.rate` parameter hard-caps at 2.0× — values
// above silently clamp. We match the old Menu options 1:1.
import SwiftUI

public struct SpeedChips: View {
    /// Currently selected speed.
    public let current: Double
    public let onSelect: (Double) -> Void

    public static let options: [Double] = [0.75, 1.0, 1.2, 1.5, 1.75, 2.0]

    public init(current: Double, onSelect: @escaping (Double) -> Void) {
        self.current = current
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.options, id: \.self) { value in
                SpeedChip(
                    value: value,
                    isSelected: isSelected(value),
                    onSelect: { onSelect(value) }
                )
            }
        }
    }

    private func isSelected(_ value: Double) -> Bool {
        abs(current - value) < 0.01
    }
}

private struct SpeedChip: View {
    let value: Double
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Text(formatted)
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(isSelected ? PopoverDesign.bodyColor : PopoverDesign.secondaryColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
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

    private var formatted: String {
        // 0.75 → "0.75×"; 1.0 → "1×"; 1.2 → "1.2×"; 2.0 → "2×"
        let whole = value.rounded() == value
        if whole {
            return "\(Int(value))×"
        }
        let stripped = String(format: "%.2f", value).trimmingTrailingZeros()
        return "\(stripped)×"
    }

    private var fillColor: Color {
        if isPressed { return PopoverDesign.pressedFill }
        if isHovering { return PopoverDesign.hoverFill }
        if isSelected { return PopoverDesign.accent.opacity(0.18) }
        return Color.white.opacity(0.03)
    }
}

extension String {
    fileprivate func trimmingTrailingZeros() -> String {
        guard contains(".") else { return self }
        var result = self
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }
}
