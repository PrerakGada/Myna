// PillController+Positioning.swift — where the floating pill sits: the
// screen under the cursor, a user-dragged anchor, expand/collapse in place,
// and recovery when displays come and go. Split out of PillController.swift
// to keep that file under SwiftLint's length limits.
import AppKit
import QuartzCore

extension PillController {
    // MARK: - positioning
    //
    // Two regimes:
    //   (1) User has NOT dragged the pill — we own positioning and
    //       snap to bottom-centre of the screen-under-cursor on every
    //       show / screen change / app activation.
    //   (2) User HAS dragged the pill — AppKit's frame autosave owns
    //       the origin. We only touch the size component when the
    //       pill expands/collapses, and we validate the origin is
    //       still on-screen (display unplug fallback).

    /// Returns the screen that contains the given cursor point. Falls
    /// back to `screens.first(where: NSScreen.main)` then to the head
    /// of the screens array.
    ///
    /// Exposed `internal` for testing — the test target uses
    /// `@testable import` and can call this with injected arrays
    /// without needing real displays.
    static func screenForCursor(
        _ cursor: CGPoint,
        screens: [NSScreen],
        main: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        if let hit = screens.first(where: { $0.frame.contains(cursor) }) {
            return hit
        }
        if let main, screens.contains(where: { $0 === main }) {
            return main
        }
        return screens.first
    }

    /// The screen the pill should appear on right now. Cursor-based,
    /// which mirrors every modern multi-display utility and is what
    /// the user expects (their cursor lives on the display they're
    /// looking at).
    func targetScreen() -> NSScreen? {
        Self.screenForCursor(
            NSEvent.mouseLocation,
            screens: NSScreen.screens
        )
    }

    func repositionWindow(forLayoutChange: Bool = false) {
        guard let window, let cursorScreen = targetScreen() else { return }
        if window.isDragging {
            // Don't fight a live drag — AppKit owns the frame for the
            // duration. The drag-end notification will re-trigger us
            // if anything else needs to settle.
            return
        }

        // Size the panel to fit its content view.
        window.layoutIfNeeded()
        let fitting = hostingView?.fittingSize ?? window.frame.size
        let size = CGSize(
            width: max(80, fitting.width),
            height: max(pillMinHeight, fitting.height)
        )

        let origin: CGPoint
        if forLayoutChange, window.frame.width > 1 {
            // Expand/collapse in place: hold the bottom edge fixed and
            // re-centre horizontally on the pill's current centre, so the
            // panel grows upward (and symmetrically) with no anchor drift.
            // Bottom-left origin → holding origin.y constant grows upward.
            origin = CGPoint(x: window.frame.midX - size.width / 2, y: window.frame.minY)
        } else if let anchor = PillAnchorStore.load() {
            // User has positioned the pill: restore from the saved
            // (display, fractional-offset) anchor at the current size. If the
            // saved display is gone, restoredFrame falls back to the cursor
            // screen — the clamp below guarantees it's never off-screen.
            origin = PillAnchorStore.restoredFrame(
                for: anchor, size: size,
                screens: NSScreen.screens, fallback: cursorScreen
            ).origin
        } else {
            // Default: bottom-centre of the screen under the cursor.
            origin = bottomCenterFrame(
                on: cursorScreen, width: size.width, height: size.height
            ).origin
        }

        // Always clamp the final frame to the visible frame of the screen it
        // sits on — the one guarantee the pill can never be stranded.
        let centre = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? cursorScreen
        let target = PillAnchorStore.clamp(
            NSRect(origin: origin, size: size), in: screen.visibleFrame)

        if forLayoutChange {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
            }
        } else {
            window.setFrame(target, display: true, animate: false)
        }
    }

    func bottomCenterFrame(
        on screen: NSScreen,
        width: CGFloat,
        height: CGFloat
    ) -> NSRect {
        let visible = screen.visibleFrame  // accounts for Dock/menu bar
        let x = visible.midX - width / 2
        let y = visible.minY + Self.bottomMargin
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func isFrameOnAnyScreen(_ frame: NSRect) -> Bool {
        // Require at least 80% of the pill's width to be on some
        // screen — a sliver hanging off the edge still counts as
        // "visible enough". Avoids panicking on small display
        // arrangement changes (e.g. a 1px row of pixels off-screen).
        let minOverlap: CGFloat = 0.8
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            if intersection.width >= frame.width * minOverlap {
                return true
            }
        }
        return false
    }

    func handleScreenChange() {
        // Display arrangement changed (plug/unplug, sleep/wake). These arrive
        // in storms, sometimes with a transient empty/degenerate screen set.
        // Debounce so we reposition once things settle, and skip ticks where
        // no screens are reported. The clamp in repositionWindow then re-snaps
        // any now-off-screen custom position back onto a visible display.
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !NSScreen.screens.isEmpty else { return }
            self.repositionWindow()
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.screenChangeDebounce, execute: work)
    }

    func handleUserDrag() {
        // Persist the new position as a (display, fractional-offset)
        // anchor — but only if the pill is genuinely on-screen. Never
        // re-save an off-screen frame; that's exactly how the old
        // absolute autosave stranded the pill at (-942, 1144). We save
        // against the screen holding the pill's *centre* (the cursor may
        // have drifted off the pill by drag-end).
        if let window, isFrameOnAnyScreen(window.frame) {
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) }
                ?? targetScreen()
            if let screen {
                PillAnchorStore.save(frame: window.frame, on: screen)
            }
        }
        // Refresh any UI bound to the controller (e.g. a future
        // "pill is at custom position" indicator).
        objectWillChange.send()
    }
}

/// Lifted from the design tokens in PillView (file-private there). Keep
/// small and out of the view-model so the controller doesn't have to
/// import SwiftUI just for a number. 16pt is the collapsed thin-bar's hit
/// height (CollapsedBar.hitHeight) — the floor only bites for that state;
/// the expanded mini-player always measures much taller.
private let pillMinHeight: CGFloat = 16
