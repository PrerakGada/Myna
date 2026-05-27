// OnboardingWindow.swift — NSWindow controller for the first-run
// cinematic. Centered, borderless-ish (titled but hidden), 720×480.
// Closes when the controller reaches `.completed` or `.skipped`.
import AppKit
import Combine
import SwiftUI

/// Singleton launcher mirrors WhatsNewLauncher's shape: decides whether
/// to auto-show on first launch, owns the active window if any.
@MainActor
public final class OnboardingLauncher {
    public static let shared = OnboardingLauncher()

    private var window: NSWindow?
    private var phaseObservation: AnyCancellable?
    private let store: WhatsNewStateStore
    private let log = Log(.app)

    public init(store: WhatsNewStateStore = .shared) {
        self.store = store
    }

    /// Should the cinematic run? True iff state file says first run is
    /// not yet complete. Returning true here means AppDelegate should
    /// SKIP the What's New dialog (the cinematic owns that slot per
    /// S10 AC #7).
    public func isFirstRunPending() -> Bool {
        !store.load().firstRunComplete
    }

    /// Present the cinematic window. Idempotent — re-uses an existing
    /// window if already open. Returns false if there are no slides to
    /// show or if the window couldn't be constructed.
    @discardableResult
    public func present(client: DaemonClient?, player: AudioPlayer?, settings: SettingsViewModel?) -> Bool {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        let voice = settings?.voice
        let speed = settings?.defaultSpeed ?? 1.0
        let controller = OnboardingController(
            client: client,
            player: player,
            voice: voice,
            speed: speed
        )
        // Observe phase so we tear down the window when the user
        // finishes or skips.
        phaseObservation = controller.$phase.sink { [weak self] phase in
            switch phase {
            case .completed, .skipped:
                self?.dismiss()
            case .showing:
                break
            }
        }
        let win = OnboardingWindow(controller: controller)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        // Kick off the script after the window is up so the first
        // slide's animation has a frame to land on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            controller.start()
        }
        log.info("OnboardingLauncher: presented cinematic")
        return true
    }

    private func dismiss() {
        // Close on the next runloop so any in-flight Combine sink
        // finishes before the window deallocs.
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            self?.window = nil
            self?.phaseObservation = nil
        }
    }
}

/// The window itself. Standard titled window (so users can quit with
/// Cmd-W) but with a hidden title bar so the cinematic feels cinematic.
@MainActor
final class OnboardingWindow: NSWindow {
    init(controller: OnboardingController) {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Welcome to Myna"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // Match the WhatsNewWindow trick: standardWindowButton lookup
        // lets us hide the traffic-light buttons we don't want without
        // dropping the titled style entirely.
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true

        let host = NSHostingView(rootView: OnboardingView(controller: controller))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        contentView = host

        // Closing the window mid-flow is treated as a skip — persists
        // first_run_complete=true so the cinematic doesn't re-fire on
        // every relaunch. Per S11 AC #8 (Cmd-Q mid-cinematic saves state).
        let proxy = ClosingProxy { [weak controller] in
            controller?.skip()
        }
        self.closingProxy = proxy
        delegate = proxy
    }

    private var closingProxy: ClosingProxy?
}

private final class ClosingProxy: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
