// FloatingPillWindow.swift — NSPanel subclass that hosts the pill UI.
//
// Requirements:
//   - Never becomes key, never becomes main, never steals focus from
//     the foreground app. This is crucial: the pill exists alongside
//     the user's editor / browser, not in front of it.
//   - Floats above ordinary windows, joins every Space and works in
//     full-screen apps (so reading-mode-while-watching-video still
//     surfaces the pill).
//   - Background is transparent at the AppKit layer so the SwiftUI
//     view can render its own rounded-pill material background.
//   - Has no shadow at the window level (SwiftUI will apply its own
//     subtle shadow inside the pill shape — a window-level shadow
//     gives away the rectangular bounds and looks wrong on a pill).
//   - Click-or-drag from anywhere on the surface. We override
//     mouseDown(with:) and disambiguate between a tap and a drag
//     by tracking subsequent events ourselves: if the cursor moves
//     more than `dragThreshold` points before mouseUp we hand off
//     to performDrag(with:); otherwise we fire `onBackgroundTap`
//     (PillController wires it to viewModel.togglePin()). This
//     gives us:
//       • clean tap-to-pin without accidental window nudges (the
//         old code called performDrag on every mouseDown, so any
//         single click that happened to land outside a SwiftUI
//         button would drag the pill — and any cursor twitch
//         during a click would shove it to the cursor)
//       • AppKit-native drag (correct cursor, edge snap, multi-
//         display geometry) without us touching frame math
//     SwiftUI DragGesture inside a borderless panel is fragile (it
//     races SwiftUI's own hit-test for the transport buttons), so
//     we keep dragging at the AppKit layer. SwiftUI .onTapGesture
//     on the pill body never fires once mouseDown is intercepted
//     at the window — the tap is delivered via onBackgroundTap.
//   - Does NOT persist its own frame (no setFrameAutosaveName — that
//     saves absolute origins and stranded the pill off-screen at
//     -942,1144 when the saved display went away). Position is owned by
//     PillController via PillAnchorStore (display id + fractional offset,
//     clamped to the visible frame). The legacy `dev.myna.app.pillFrame`
//     key is only cleared on "Reset pill position".
//
// Why NSPanel + .nonactivatingPanel:
//   `NSWindow` would steal focus on click. `.nonactivatingPanel`
//   tells AppKit "don't activate this app when this panel becomes
//   front", which is what an HUD wants.
import AppKit

/// UserDefaults key that AppKit reads/writes under
/// `NSWindow Frame <name>` when setFrameAutosaveName is set. We
/// expose the bare autosave name so PillController can clear the
/// stored value (Reset pill position) without reaching into
/// AppKit-internal key formatting.
public enum FloatingPillFrame {
    /// Autosave name passed to setFrameAutosaveName. AppKit prefixes
    /// "NSWindow Frame " internally when persisting.
    public static let autosaveName = "dev.myna.app.pillFrame"
    /// The actual UserDefaults key AppKit writes under. Useful for
    /// tests and for the Reset action to clear directly.
    public static let defaultsKey = "NSWindow Frame \(autosaveName)"
}

/// Subclass primarily so we can lock `canBecomeKey` / `canBecomeMain`
/// to false (the default NSPanel implementation returns `true` for
/// canBecomeKey when the panel has any focusable subview — our SwiftUI
/// buttons would activate that path).
///
/// Also handles AppKit-native click-and-drag on the panel background:
/// `mouseDown(with:)` tracks events and decides — based on whether the
/// cursor moves more than `dragThreshold` points before mouseUp —
/// whether to start a window drag (via `performDrag(with:)`) or fire
/// the `onBackgroundTap` callback (which PillController routes to
/// viewModel.togglePin()). SwiftUI child controls (transport buttons,
/// close button) consume their own mouseDown first, so they're
/// unaffected — only mouseDowns that reach the panel surface enter
/// this disambiguation path.
public final class FloatingPillWindow: NSPanel {
    /// Notification posted when the user finishes a drag *that actually
    /// moved the window*. PillController listens for this so it can stop
    /// auto-repositioning the pill (the user has expressed a position
    /// preference). Not posted on a bare click or a sub-threshold twitch
    /// — those are taps, not position changes.
    public static let didMoveByUserNotification = Notification.Name(
        "dev.myna.app.FloatingPillWindow.didMoveByUser"
    )

    /// Minimum cursor travel (in points, from the mouseDown location)
    /// required before we treat a press-and-move as a window drag.
    /// Below this we treat the gesture as a tap and forward to the
    /// `onBackgroundTap` callback — keeps single-clicks from nudging
    /// the pill and resurrects the click-to-pin gesture that the
    /// previous "always performDrag" code path silently swallowed.
    /// 4pt is roughly what AppKit uses internally for window-drag
    /// detection on isMovableByWindowBackground.
    public static let dragThreshold: CGFloat = 4

    /// True while the user has explicitly positioned the pill. Until
    /// the first user-drag *that moved the origin* (or a successful
    /// autosave restore), PillController owns positioning. After,
    /// PillController defers to the saved frame.
    public private(set) var hasUserPosition: Bool = false

    /// True only for the brief window between mouseDown and mouseUp
    /// while a user drag is in flight. Read by PillController so it
    /// doesn't fight the drag with a reposition.
    public private(set) var isDragging: Bool = false

    /// Callback fired when the user clicks (no drag) anywhere on the
    /// panel background. PillController sets this to route to
    /// viewModel.togglePin(). nil-by-default so tests can omit it
    /// without wiring; in production it's always set in
    /// PillController.ensureWindow().
    ///
    /// Typed @MainActor because the invocation site (`mouseDown`) is
    /// AppKit-isolated to the main actor, and the natural callback
    /// body touches the view model directly without a Task hop.
    public var onBackgroundTap: (@MainActor () -> Void)?

    public init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Transparent background — the SwiftUI view paints its own pill.
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false

        // Float above app windows but below the menu bar and below
        // system alerts. .statusBar is too aggressive; .floating sits
        // nicely just above ordinary content windows.
        self.level = .floating

        // Be present on every Space, including full-screen apps.
        // .stationary keeps the position fixed when the user swipes
        // between Spaces (otherwise it'd "slide" with the desktop).
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Don't show up in Window menu, Mission Control, screenshots
        // of "all windows", or the app switcher.
        self.isExcludedFromWindowsMenu = true

        // Allow click-through prevention: we *do* want clicks on the
        // pill to land (for hover/expand and pin), so we keep
        // ignoresMouseEvents = false (its default).
        self.ignoresMouseEvents = false

        // No title bar / no traffic-light buttons.
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true

        // We do our own dragging via performDrag(with:) in
        // mouseDown — leaving isMovableByWindowBackground = false
        // ensures AppKit doesn't compete with us for the gesture.
        // isMovable stays true so performDrag(with:) is allowed.
        self.isMovableByWindowBackground = false
        self.isMovable = true

        // Animate frame changes (resize between collapsed/expanded).
        self.animationBehavior = .utilityWindow

        self.contentView = contentView

        // Default visibility: hidden. PillController shows it when
        // playback starts.
        self.alphaValue = 0
        self.orderOut(nil)

        // Frame autosave is intentionally NOT used. setFrameAutosaveName
        // persists an *absolute* origin, which strands the pill off-screen
        // when the display it was saved on goes away (the real -942,1144
        // bug). Position is owned by PillController via PillAnchorStore:
        // it persists a display id + fractional offset and clamps to the
        // visible frame on every restore. `hasUserPosition` stays false
        // until the user actually drags the pill.
    }

    /// Locked to false. The pill must never accept keyboard focus —
    /// that would yank focus from the user's editor and break typing.
    public override var canBecomeKey: Bool { false }

    /// Locked to false. There is no "main window" semantic for an HUD.
    public override var canBecomeMain: Bool { false }

    /// Required by NSWindow but we never use it.
    public override var acceptsFirstResponder: Bool { false }

    // MARK: - click / drag handling
    //
    // mouseDown on a borderless panel doesn't start a drag by
    // default — we have to opt in. AppKit's
    // `isMovableByWindowBackground = true` would also work, but it
    // drags on *any* background mouseDown (no movement threshold),
    // so click-to-pin can't coexist with it. We instead run our
    // own tracking loop:
    //
    //   1. Capture press location and current frame.origin.
    //   2. Pull subsequent leftMouseDragged / leftMouseUp events
    //      until one of:
    //        (a) cumulative travel from the press point exceeds
    //            `dragThreshold` → hand that event to
    //            performDrag(with:), which then takes over until
    //            mouseUp.
    //        (b) leftMouseUp arrives first → it was a tap; fire
    //            `onBackgroundTap` so PillController.togglePin()
    //            runs.
    //   3. After performDrag returns, only set hasUserPosition
    //      (and post didMoveByUserNotification) if frame.origin
    //      actually changed. A drag the user instantly cancels
    //      should not lock the pill in place — that's the bug
    //      that left Prerak's pill stuck at (-942, 1144) until
    //      the v0.2.x reset path was wired up.
    //
    // SwiftUI buttons inside the panel intercept mouseDown via
    // their own NSResponder and don't forward here — transport /
    // close controls are unaffected. Only mouseDowns that reach
    // the panel surface itself enter this disambiguation path.
    //
    // The event-tracking step is extracted to a pure static helper
    // (`trackDragOrTap`) so tests can verify the click/drag
    // boundary with synthetic NSEvents — no event loop required.
    public override func mouseDown(with event: NSEvent) {
        let startLocation = event.locationInWindow
        let originBefore = frame.origin

        let result = Self.trackDragOrTap(
            startLocation: startLocation,
            threshold: Self.dragThreshold,
            nextEvent: {
                NSApp.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: .distantFuture,
                    inMode: .eventTracking,
                    dequeue: true
                )
            }
        )

        switch result {
        case .drag(let initiator):
            isDragging = true
            performDrag(with: initiator)
            isDragging = false
            // performDrag returns immediately on mouseUp; even
            // after we passed the threshold the frame can end
            // unchanged in degenerate cases (user moved exactly
            // threshold pts and back). Only commit
            // hasUserPosition if the origin actually shifted.
            if frame.origin != originBefore {
                hasUserPosition = true
                NotificationCenter.default.post(
                    name: Self.didMoveByUserNotification,
                    object: self
                )
            }
        case .tap:
            onBackgroundTap?()
        }
    }

    // MARK: - testable disambiguator

    /// Outcome of `trackDragOrTap`. `.tap` means the user released
    /// without dragging; `.drag` carries the first mouseDragged
    /// event past `dragThreshold` so the caller can hand it
    /// straight to `performDrag(with:)`.
    internal enum MouseTrackResult {
        case tap
        case drag(NSEvent)
    }

    /// Pull events from `nextEvent` and classify the gesture.
    ///
    /// Pure with respect to the injected event source — tests pass
    /// a closure that returns synthetic NSEvents from a fixed
    /// sequence, so we can verify the click/drag boundary without
    /// pumping a real event loop.
    ///
    /// Returns `.tap` if the stream is exhausted before a
    /// past-threshold mouseDragged arrives — defensive only;
    /// production's NSApp.nextEvent waits forever and only ever
    /// returns a real event.
    @MainActor
    internal static func trackDragOrTap(
        startLocation: NSPoint,
        threshold: CGFloat,
        nextEvent: () -> NSEvent?
    ) -> MouseTrackResult {
        while let event = nextEvent() {
            switch event.type {
            case .leftMouseUp:
                return .tap
            case .leftMouseDragged:
                let dx = event.locationInWindow.x - startLocation.x
                let dy = event.locationInWindow.y - startLocation.y
                if hypot(dx, dy) >= threshold {
                    return .drag(event)
                }
            default:
                continue
            }
        }
        return .tap
    }
}
