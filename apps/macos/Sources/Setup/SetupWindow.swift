// SetupWindow.swift — window + singleton launcher for the first-launch
// installer. Mirrors OnboardingLauncher/OnboardingWindow. Unlike onboarding it
// isn't gated on a first-run flag: AppDelegate shows it whenever the voice
// engine is missing or down.
import AppKit
import SwiftUI

@MainActor
public final class SetupLauncher {
    public static let shared = SetupLauncher()

    private var window: NSWindow?
    private var controller: SetupController?
    private var onFinish: ((Bool) -> Void)?
    private let log = Log(.app)

    public init() {}

    /// Present the installer. Idempotent — re-uses an existing window.
    /// `onFinish` runs once the window closes, with whether setup succeeded.
    @discardableResult
    public func present(onFinish: @escaping (_ succeeded: Bool) -> Void = { _ in }) -> Bool {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        let controller = SetupController()
        let win = SetupWindow(
            controller: controller,
            onClose: { [weak self] in self?.dismiss() },
            onWindowClosed: { [weak self] in self?.windowClosed() }
        )
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.controller = controller
        self.onFinish = onFinish
        window = win
        log.info("SetupLauncher: presented setup window")
        return true
    }

    private func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
        }
    }

    /// Runs for every close: the buttons and the title-bar ✕ alike.
    private func windowClosed() {
        guard window != nil else { return }
        let succeeded = controller?.phase == .succeeded
        controller?.close()
        window = nil
        controller = nil
        let finish = onFinish
        onFinish = nil
        log.info("SetupLauncher: closed setup window (succeeded: \(succeeded))")
        finish?(succeeded)
    }
}

@MainActor
final class SetupWindow: NSWindow {
    /// Taller only when the "running from the disk image" banner can appear.
    static func size(for location: SetupController.Location) -> NSSize {
        NSSize(width: 600, height: location == .temporary ? 680 : 600)
    }

    /// Height shared by the step list and the details panel that replaces it.
    static let listHeight: CGFloat = 318

    private var closingProxy: SetupWindowClosingProxy?

    init(controller: SetupController, onClose: @escaping () -> Void, onWindowClosed: @escaping () -> Void) {
        let frame = NSRect(origin: .zero, size: Self.size(for: controller.location))
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
        // the user clicks Continue / Not now / Close (or the title-bar ✕). Opt
        // out so ARC is the sole owner. (Matches WhatsNewWindow + CCToastWindow.)
        isReleasedWhenClosed = false
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true

        let host = NSHostingView(rootView: SetupView(controller: controller, onClose: onClose))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        contentView = host

        let proxy = SetupWindowClosingProxy(onClose: onWindowClosed)
        closingProxy = proxy
        delegate = proxy
    }
}

private final class SetupWindowClosingProxy: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
