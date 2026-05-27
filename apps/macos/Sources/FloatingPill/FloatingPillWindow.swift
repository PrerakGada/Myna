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
//
// Why NSPanel + .nonactivatingPanel:
//   `NSWindow` would steal focus on click. `.nonactivatingPanel`
//   tells AppKit "don't activate this app when this panel becomes
//   front", which is what an HUD wants.
import AppKit

/// Subclass primarily so we can lock `canBecomeKey` / `canBecomeMain`
/// to false. The default NSPanel implementation returns `true` for
/// canBecomeKey when the panel has any focusable subview — our SwiftUI
/// buttons would activate that path.
public final class FloatingPillWindow: NSPanel {
    public init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 28),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
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

        // Movable by drag would let the user accidentally drag the pill
        // around; we want it pinned to bottom-center of the active
        // screen.
        self.isMovableByWindowBackground = false
        self.isMovable = false

        // Animate frame changes (resize between collapsed/expanded).
        self.animationBehavior = .utilityWindow

        self.contentView = contentView

        // Default visibility: hidden. PillController shows it when
        // playback starts.
        self.alphaValue = 0
        self.orderOut(nil)
    }

    /// Locked to false. The pill must never accept keyboard focus —
    /// that would yank focus from the user's editor and break typing.
    public override var canBecomeKey: Bool { false }

    /// Locked to false. There is no "main window" semantic for an HUD.
    public override var canBecomeMain: Bool { false }

    /// Required by NSWindow but we never use it.
    public override var acceptsFirstResponder: Bool { false }
}
