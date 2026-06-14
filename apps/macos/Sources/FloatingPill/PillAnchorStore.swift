// PillAnchorStore.swift — durable, display-aware position persistence for
// the floating pill. Replaces AppKit's setFrameAutosaveName, which saved an
// absolute origin and stranded the pill off-screen (-942,1144) when the
// display it was saved on disappeared.
//
// Model: persist (displayID, fx, fy) where fx/fy are the pill origin's
// fractional offset within the target screen's visibleFrame. On restore we
// find the screen by its stable CGDirectDisplayID (NOT the screens-array
// index, which reorders), recompute the absolute origin for the *current*
// visibleFrame, and CLAMP to that visibleFrame. The clamp runs on every
// restore, so even a corrupt/stale anchor can never put the pill off-screen.
//
// The geometry math is pure (operates on NSRect, no NSScreen) so it's unit-
// testable without real displays; the NSScreen lookups are thin adapters.
import AppKit

@MainActor
public enum PillAnchorStore {
    // New UserDefaults keys. The legacy autosave key (FloatingPillFrame) is
    // cleared separately by PillController.resetPosition for migration.
    static let displayIDKey = "dev.myna.app.pillAnchor.displayID"
    static let fxKey = "dev.myna.app.pillAnchor.fx"
    static let fyKey = "dev.myna.app.pillAnchor.fy"
    static let presentKey = "dev.myna.app.pillAnchor.present"

    /// A persisted position: a stable display id + the origin's fractional
    /// offset within that display's visibleFrame.
    public struct Anchor: Equatable {
        public var displayID: CGDirectDisplayID
        public var fx: CGFloat
        public var fy: CGFloat
        public init(displayID: CGDirectDisplayID, fx: CGFloat, fy: CGFloat) {
            self.displayID = displayID
            self.fx = fx
            self.fy = fy
        }
    }

    // MARK: - pure geometry (unit-tested; no NSScreen)

    /// Fractional offset of `frame`'s origin within `visibleFrame`.
    /// Returns nil for a degenerate (zero-area) visible frame.
    static func fractionalOffset(of frame: NSRect, in visibleFrame: NSRect) -> CGPoint? {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
        return CGPoint(
            x: (frame.minX - visibleFrame.minX) / visibleFrame.width,
            y: (frame.minY - visibleFrame.minY) / visibleFrame.height
        )
    }

    /// Absolute origin for fractional offsets within `visibleFrame`.
    static func origin(fx: CGFloat, fy: CGFloat, in visibleFrame: NSRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.minX + fx * visibleFrame.width,
            y: visibleFrame.minY + fy * visibleFrame.height
        )
    }

    /// Clamp `frame` fully inside `visibleFrame`, keeping `margin` from each
    /// edge. The nested min(max(...)) pins both edges; if the pill is wider/
    /// taller than the screen it pins to the far edge (acceptable). This is
    /// the single guarantee that the pill can never be stranded off-screen.
    static func clamp(_ frame: NSRect, in visibleFrame: NSRect, margin: CGFloat = 8) -> NSRect {
        var r = frame
        r.origin.x = min(max(r.minX, visibleFrame.minX + margin),
                         visibleFrame.maxX - r.width - margin)
        r.origin.y = min(max(r.minY, visibleFrame.minY + margin),
                         visibleFrame.maxY - r.height - margin)
        return r
    }

    // MARK: - NSScreen adapters

    /// Stable hardware display id for a screen (survives reboot/sleep/dock,
    /// unlike the screens-array index). nil if AppKit doesn't report it.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let n = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(n.uint32Value)
    }

    /// The screen matching a saved displayID, if still attached.
    static func screen(for displayID: CGDirectDisplayID, in screens: [NSScreen]) -> NSScreen? {
        screens.first { self.displayID(of: $0) == displayID }
    }

    /// Clamped frame for a saved anchor at the given size. Falls back to
    /// `fallback`'s visibleFrame (same fractional offset, then clamped) if
    /// the saved display is gone.
    static func restoredFrame(
        for anchor: Anchor,
        size: CGSize,
        screens: [NSScreen],
        fallback: NSScreen
    ) -> NSRect {
        let target = screen(for: anchor.displayID, in: screens) ?? fallback
        let vf = target.visibleFrame
        let o = origin(fx: anchor.fx, fy: anchor.fy, in: vf)
        return clamp(NSRect(origin: o, size: size), in: vf)
    }

    // MARK: - persistence

    public static func load(defaults: UserDefaults = .standard) -> Anchor? {
        guard defaults.bool(forKey: presentKey) else { return nil }
        let id = CGDirectDisplayID(UInt32(truncatingIfNeeded: defaults.integer(forKey: displayIDKey)))
        return Anchor(
            displayID: id,
            fx: CGFloat(defaults.double(forKey: fxKey)),
            fy: CGFloat(defaults.double(forKey: fyKey))
        )
    }

    /// Persist the pill's current frame as an anchor on the given screen.
    /// No-op (leaving any prior anchor intact) if the screen has no display
    /// id or a degenerate visible frame.
    static func save(frame: NSRect, on screen: NSScreen, defaults: UserDefaults = .standard) {
        guard let id = displayID(of: screen),
              let f = fractionalOffset(of: frame, in: screen.visibleFrame) else { return }
        defaults.set(Int(id), forKey: displayIDKey)
        defaults.set(Double(f.x), forKey: fxKey)
        defaults.set(Double(f.y), forKey: fyKey)
        defaults.set(true, forKey: presentKey)
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: displayIDKey)
        defaults.removeObject(forKey: fxKey)
        defaults.removeObject(forKey: fyKey)
        defaults.removeObject(forKey: presentKey)
    }
}
