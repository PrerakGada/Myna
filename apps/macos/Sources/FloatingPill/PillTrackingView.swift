// PillTrackingView.swift — a thin NSView that owns the NSTrackingArea for the
// floating pill's hover detection, and hosts the SwiftUI content as a subview.
//
// Why AppKit tracking instead of SwiftUI `.onHover`: `.onHover` drops the
// mouseExited callback when the cursor leaves a small target at speed, so the
// pill would sometimes stay expanded forever. An NSTrackingArea with
// `.activeAlways` fires reliably even though the pill's panel is never key.
//
// Tracking is enter/exit only — it never consumes a click. We deliberately do
// NOT override mouseDown, so background presses still fall through the
// responder chain to FloatingPillWindow.mouseDown, which runs the tap-vs-drag
// disambiguation. `.inVisibleRect` makes the tracking area follow our bounds
// across the expand/collapse resize with no manual rect math.
import AppKit

final class PillTrackingView: NSView {
    /// Called on the main thread when the cursor enters (true) or exits
    /// (false) the pill. PillController debounces the exit before collapsing.
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
