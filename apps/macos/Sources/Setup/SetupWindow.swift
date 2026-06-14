// SetupWindow.swift — window + singleton launcher for the "Finish setup" flow.
// Mirrors OnboardingLauncher/OnboardingWindow. The window stays up until the
// user finishes (the SetupView's buttons call onClose); unlike onboarding it
// isn't gated on a first-run flag — it's shown whenever the engine is missing
// and from the menu-bar "Run Setup" action.
import AppKit
import SwiftUI

@MainActor
public final class SetupLauncher {
    public static let shared = SetupLauncher()

    private var window: NSWindow?
    private let log = Log(.app)

    public init() {}

    /// Present the setup window. Idempotent — re-uses an existing window.
    @discardableResult
    public func present(client: DaemonClient?) -> Bool {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        let controller = SetupController(client: client)
        let win = SetupWindow(controller: controller) { [weak self] in self?.dismiss() }
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        log.info("SetupLauncher: presented setup window")
        return true
    }

    private func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
        }
    }
}

@MainActor
final class SetupWindow: NSWindow {
    init(controller: SetupController, onClose: @escaping () -> Void) {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 440)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Set up Myna"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // SetupLauncher holds a strong reference and nils it on close. With
        // the AppKit default (isReleasedWhenClosed = true) AppKit ALSO releases
        // the window on close — a double-free that crashes the app the moment
        // the user clicks Done / Not now / Close (or the title-bar ✕). Opt out
        // so ARC is the sole owner. (Matches WhatsNewWindow + CCToastWindow.)
        isReleasedWhenClosed = false
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true

        let host = NSHostingView(rootView: SetupView(controller: controller, onClose: onClose))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}
