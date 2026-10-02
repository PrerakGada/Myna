// FeedbackWindow.swift — the window behind "Report a Problem…" and
// "Send Feedback…". Mirrors SetupLauncher/SetupWindow.
//
// It has to be a real, activated window: the menu-bar popover is never key
// (see popover-window-constraints), so nothing typed there would arrive.
import AppKit
import SwiftUI

@MainActor
public final class FeedbackLauncher {
    public static let shared = FeedbackLauncher()

    /// Offline until AppDelegate.bootstrap() installs a real FeedbackClient,
    /// which happens only for an interactive launch — never under XCTest.
    public var sender: any FeedbackSending = OfflineFeedbackSender()

    private var window: FeedbackWindow?
    private var model: FeedbackFormModel?
    private let log = Log(.app)

    public init() {}

    /// Open the form with `kind` preselected. One window at a time: asking
    /// again brings it forward and keeps whatever is typed.
    public func present(kind: FeedbackKind) {
        if let window, let model {
            model.prepare(for: kind)
            bringForward(window)
            return
        }
        let model = FeedbackFormModel(kind: kind, context: .current(), sender: sender)
        let win = FeedbackWindow(
            model: model,
            onClose: { [weak self] in self?.dismiss() },
            onWindowClosed: { [weak self] in self?.windowClosed() }
        )
        win.center()
        self.model = model
        window = win
        bringForward(win)
        log.info("FeedbackLauncher: presented feedback window (\(kind.rawValue))")
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
        }
    }

    /// Runs for every close: Cancel, Close and the title-bar ✕ alike.
    private func windowClosed() {
        model?.cancel()
        model = nil
        window = nil
    }
}

@MainActor
final class FeedbackWindow: NSWindow {
    static let contentSize = NSSize(width: 460, height: 460)

    private var closingProxy: FeedbackWindowClosingProxy?

    init(model: FeedbackFormModel, onClose: @escaping () -> Void, onWindowClosed: @escaping () -> Void) {
        let frame = NSRect(origin: .zero, size: Self.contentSize)
        super.init(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Myna Feedback"
        // FeedbackLauncher owns the window; AppKit releasing it on close as
        // well would double-free it (see SetupWindow).
        isReleasedWhenClosed = false
        // Open on the Space the user is looking at.
        collectionBehavior = [.moveToActiveSpace]
        // An accessory app has no Dock icon to restore a minimized window from.
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let host = NSHostingView(rootView: FeedbackView(model: model, onClose: onClose))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        contentView = host

        let proxy = FeedbackWindowClosingProxy(onClose: onWindowClosed)
        closingProxy = proxy
        delegate = proxy
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Myna is an accessory app, so the editing shortcuts can't count on a
    /// visible Edit menu. Route them to the focused field directly, and let
    /// Esc close the thank-you view (the form's Cancel button owns it before).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        if Self.isEscape(event) {
            performClose(nil)
            return true
        }
        guard let action = Self.editAction(for: event) else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch (flags, key) {
        case (.command, "x"): return #selector(NSText.cut(_:))
        case (.command, "c"): return #selector(NSText.copy(_:))
        case (.command, "v"): return #selector(NSText.paste(_:))
        case (.command, "a"): return #selector(NSText.selectAll(_:))
        case (.command, "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }

    private static func isEscape(_ event: NSEvent) -> Bool {
        event.keyCode == 53 && event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control])
    }
}

private final class FeedbackWindowClosingProxy: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
