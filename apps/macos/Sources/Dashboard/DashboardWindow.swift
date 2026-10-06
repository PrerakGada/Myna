// DashboardWindow.swift — Myna's real application window.
//
// Everything before v0.6 was transient: a popover that closes when you
// look away, a Settings scene of seven fixed-size tabs, three one-shot
// windows. This is the one surface you can leave open on a second
// monitor.
//
// Activation policy is the interesting part. Myna ships as LSUIElement
// (menu-bar only, no Dock icon), and an .accessory app's windows cannot
// reliably become key, own a menu bar, or be reached with ⌘-Tab — the
// same root cause documented at length in SettingsWindowActivator. So
// the launcher promotes the process to .regular while the Dashboard is
// open and demotes it back to .accessory when it closes. That gives a
// real window with a real Dock icon for as long as it is up, and leaves
// the app invisible again afterwards.
//
// Follows the WhatsNewLauncher / OnboardingLauncher pattern already in
// the codebase: a @MainActor singleton owning an NSWindow that hosts a
// SwiftUI root, with isReleasedWhenClosed = false so ARC is the sole
// owner.
import AppKit
import Combine
import SwiftUI

/// Everything the Dashboard needs from the app. Assembled once by
/// AppDelegate; the panes take only what they use.
@MainActor
public struct DashboardContext {
    public let client: DaemonClient
    public let player: AudioPlayer
    public let settings: SettingsViewModel
    public let history: HistoryStore
    public let menuController: MenuBarController
    public let updates: UpdateController

    public init(
        client: DaemonClient,
        player: AudioPlayer,
        settings: SettingsViewModel,
        history: HistoryStore,
        menuController: MenuBarController,
        updates: UpdateController
    ) {
        self.client = client
        self.player = player
        self.settings = settings
        self.history = history
        self.menuController = menuController
        self.updates = updates
    }
}

/// Owns the single Dashboard window and the activation-policy dance.
@MainActor
public final class DashboardLauncher: ObservableObject {
    public static let shared = DashboardLauncher()

    /// Set by AppDelegate once bootstrap completes. Until then `present`
    /// is a no-op — the same defensive posture the other launchers take.
    public var context: DashboardContext?

    /// Which pane the window shows. Published so a deep-link into an
    /// already-open window switches panes instead of doing nothing.
    @Published public var pane: DashboardPane = .overview

    private var window: NSWindow?
    private var closeProxy: DashboardCloseProxy?
    private let log = Log(.app)

    /// Frame autosave name — macOS remembers size and position across
    /// launches for free.
    static let frameAutosaveName = "dev.myna.app.dashboard"

    public init() {}

    public var isOpen: Bool { window != nil }

    /// Open the Dashboard (or raise it) at `pane`.
    @discardableResult
    public func present(pane requested: DashboardPane? = nil) -> Bool {
        guard let context else {
            log.warn("dashboard: present() before bootstrap — ignoring")
            return false
        }
        if let requested { pane = requested }

        if let existing = window {
            promoteToRegularApp()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        let root = DashboardView(context: context, launcher: self)
        let win = DashboardWindow(root: root)
        let proxy = DashboardCloseProxy { [weak self] in
            // windowWillClose arrives on the main thread; hop through the
            // main actor explicitly so this compiles under
            // SWIFT_STRICT_CONCURRENCY=complete.
            Task { @MainActor in self?.handleWindowClosed() }
        }
        closeProxy = proxy
        win.delegate = proxy
        window = win

        promoteToRegularApp()
        // setFrameAutosaveName only restores a REMEMBERED frame; the first
        // ever launch needs an explicit centre or the window lands in the
        // bottom-left corner of the screen.
        if !win.setFrameAutosaveName(Self.frameAutosaveName) || win.frame.origin == .zero {
            win.center()
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log.info("dashboard: opened at \(pane.rawValue)")
        return true
    }

    public func close() {
        window?.close()
    }

    /// Toggle — used by the menu-bar popover's Dashboard button so a
    /// second click puts it away.
    public func toggle(pane requested: DashboardPane? = nil) {
        if isOpen, requested == nil || requested == pane {
            close()
        } else {
            present(pane: requested)
        }
    }

    // MARK: - activation policy

    /// Become a normal app: Dock icon, ⌘-Tab, a real menu bar. Myna is
    /// LSUIElement, so this is what makes the window behave like a
    /// window rather than a popover that happens to have a title bar.
    private func promoteToRegularApp() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// Back to invisible. Guarded on there being no other ordinary window
    /// still up (setup, onboarding, what's-new) — demoting while one of
    /// those is visible would yank its Dock icon out from under it.
    private func demoteToAccessoryApp() {
        let hasOtherVisibleWindow = NSApp.windows.contains { candidate in
            candidate !== window
                && candidate.isVisible
                && candidate.styleMask.contains(.titled)
                && !(candidate is NSPanel)
        }
        guard !hasOtherVisibleWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleWindowClosed() {
        window = nil
        closeProxy = nil
        demoteToAccessoryApp()
        log.info("dashboard: closed")
    }
}

/// The window. Full-size content view with a transparent title bar so the
/// sidebar runs the full height, matching how Finder and Mail look.
@MainActor
final class DashboardWindow: NSWindow {
    init<Root: View>(root: Root) {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DashboardDesign.windowWidth,
                height: DashboardDesign.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Myna"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // Dark chrome to match the content; without this the traffic-light
        // strip renders light-grey over a near-black sidebar.
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(DashboardDesign.surface)
        minSize = NSSize(
            width: DashboardDesign.minWindowWidth,
            height: DashboardDesign.minWindowHeight)
        // The launcher holds the only strong reference and clears it on
        // close; AppKit's default would release it too and double-free.
        // Same reasoning as WhatsNewWindow / CCToastWindow.
        isReleasedWhenClosed = false
        tabbingMode = .disallowed

        let host = NSHostingView(rootView: AnyView(root))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    /// ⌘W closes rather than quitting, and the window must be able to
    /// become key even though the process may still be .accessory at the
    /// instant AppKit asks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Retains the close handler (NSWindow.delegate is weak). Mirrors
/// WhatsNewWindow.ClosingProxy.
private final class DashboardCloseProxy: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
