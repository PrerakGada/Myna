// PillController.swift — lifecycle owner for the floating pill.
//
// Responsibilities:
//   - lazily create the FloatingPillWindow + SwiftUI hosting view
//   - show/hide the window based on AudioPlayer.state AND the user's
//     "Show floating pill" + "Always visible" toggles
//   - position the pill on the **screen-under-cursor** on first show
//     (multi-display fix — see notes below), unless the user has
//     dragged it to a custom position (which AppKit persists via the
//     FloatingPillWindow's frame autosave)
//   - listen for screen-parameter changes, frontmost-app activations,
//     pill drag, and pill expand/collapse to keep the geometry sane
//   - expose `resetPosition()` so the menu-bar popover can clear the
//     persisted frame and re-snap the pill to bottom-centre of the
//     active screen
//
// Multi-display fix (v0.2.x item 5):
//   Previously this used AXUIElementCopyAttributeValue on the
//   frontmost app's main window to pick a screen. That path fails
//   silently when Accessibility permission isn't granted, AND the
//   AX-returned coordinates are flipped relative to NSScreen's
//   bottom-left origin which made multi-display intersection math
//   error-prone. We now use NSEvent.mouseLocation (the cursor) as
//   the source of truth — it's what every modern multi-display
//   utility uses (Magnet, Rectangle, AltTab) and it tracks the
//   display the user is *actually* looking at, which is the right
//   UX for a now-playing pill.
//
// Always-visible interaction (v0.2.x item 1):
//   When pillAlwaysVisible is ON, the pill is shown whenever Myna is
//   running. When the user has dragged the pill to a custom spot,
//   that position takes precedence — we do NOT keep snapping back
//   to bottom-centre every time playback starts.
//
// Owned by MynaApp as a @StateObject — its lifetime mirrors the app.
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class PillController: ObservableObject {
    /// Persistent UserDefaults key for the master enable toggle.
    public static let enabledDefaultsKey = "dev.myna.app.showFloatingPill"

    /// Notification name external UI (the menu-bar popover's
    /// "Reset pill position" action) posts to ask the controller to
    /// clear the persisted pill frame. Decoupled this way so
    /// MenuBarView doesn't need to import or hold a reference to
    /// the PillController instance (which would require plumbing
    /// through MynaApp.swift — outside this lane's allow-list).
    public static let resetPositionNotification = Notification.Name(
        "dev.myna.app.PillController.resetPosition"
    )

    /// Margin from the bottom edge of the screen (above the Dock if
    /// it's pinned to bottom). 28pt mirrors typical macOS HUD spacing.
    private static let bottomMargin: CGFloat = 28

    private var player: AudioPlayer?
    private var settings: SettingsViewModel?
    private let bridge: PillBridge

    private var window: FloatingPillWindow?
    private var viewModel: PillViewModel?
    private var hostingView: NSHostingView<PillView>?
    /// Long-lived subscriptions (player state, settings, defaults).
    /// Tied to start()/stop().
    private var cancellables = Set<AnyCancellable>()
    /// Subscriptions tied to the lifetime of the current window
    /// (vm.$isExpanded). Cleared when the window is recreated by
    /// resetPosition().
    private var windowCancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var didStart: Bool = false

    /// Default initialiser: produces a controller that's inert until
    /// `attach(player:, settings:)` is called. This shape supports
    /// being declared as @StateObject in MynaApp before AppDelegate
    /// has bootstrapped the AudioPlayer / SettingsViewModel singletons.
    public init(bridge: PillBridge = .shared) {
        self.bridge = bridge
    }

    /// Convenience initialiser for tests / previews that already have
    /// the dependencies.
    public convenience init(
        player: AudioPlayer,
        settings: SettingsViewModel,
        bridge: PillBridge = .shared
    ) {
        self.init(bridge: bridge)
        self.attach(player: player, settings: settings)
    }

    /// Inject the dependencies once AppDelegate has bootstrapped them.
    /// Safe to call multiple times; first call wins.
    public func attach(player: AudioPlayer, settings: SettingsViewModel) {
        guard self.player == nil else { return }
        self.player = player
        self.settings = settings
        if didStart {
            // start() was called before attach — kick observers now.
            beginObserving()
        }
    }

    deinit {
        // Note: cannot touch MainActor state here under Swift 6 strict
        // concurrency. Notification observers are removed in stop(),
        // which AppDelegate calls explicitly. NotificationCenter holds
        // weak refs to the block-based observers; leaking on dealloc
        // (the controller lives for the app lifetime anyway) is fine.
    }

    /// Begin observing the player. Idempotent — calling twice is a no-op.
    /// If `attach(player:, settings:)` has not yet been called, this
    /// records that start was requested; the real observation begins
    /// once attach() runs.
    public func start() {
        didStart = true
        guard player != nil else { return }
        beginObserving()
    }

    private func beginObserving() {
        guard cancellables.isEmpty, let player, let settings else { return }

        // Player state drives visibility.
        player.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncVisibility()
            }
            .store(in: &cancellables)

        // Settings drive visibility too — toggling pillAlwaysVisible
        // (or the master showFloatingPill via the @AppStorage path in
        // AdvancedTab) should take effect immediately.
        settings.$pillAlwaysVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncVisibility()
            }
            .store(in: &cancellables)

        // Pre-audio loading drives visibility too — this is the only
        // way the pill can appear inside ~50ms of a hotkey instead of
        // the 200-300ms gap before AudioPlayer.state flips to .playing.
        // The PillView renders a distinct "Processing…" + spinner
        // affordance for this window. See PillViewModel.isLoading and
        // AudioPlayer.isLoading for the contract.
        player.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncVisibility()
            }
            .store(in: &cancellables)

        // Screen / front-app changes re-position the pill (only when
        // the user has not dragged it to a custom spot).
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleScreenChange() }
            }
        )
        let ws = NSWorkspace.shared.notificationCenter
        notificationObservers.append(
            ws.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.repositionWindow() }
            }
        )
        // Listen for user-drag completion. Once the user has moved
        // the pill we stop snapping it back on app activations — the
        // pill stays where they put it, including across displays.
        notificationObservers.append(
            center.addObserver(
                forName: FloatingPillWindow.didMoveByUserNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleUserDrag() }
            }
        )
        // UserDefaults watcher for the @AppStorage-backed master
        // toggle (`showFloatingPill`). Combine doesn't see UserDefaults
        // writes from outside the SettingsViewModel; KVO does. Cheap
        // because there are only a handful of writes per app session.
        notificationObservers.append(
            center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.syncVisibility() }
            }
        )
        // Listen for "Reset pill position" requests from the menu-bar
        // popover (or anywhere else).
        notificationObservers.append(
            center.addObserver(
                forName: Self.resetPositionNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resetPosition() }
            }
        )

        // Apply the current state immediately.
        syncVisibility()
    }

    /// Stop observing and tear down the window. Called from
    /// AppDelegate.applicationWillTerminate.
    public func stop() {
        cancellables.removeAll()
        windowCancellables.removeAll()
        for token in notificationObservers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationObservers.removeAll()
        hideWindow()
        window = nil
        hostingView = nil
        viewModel = nil
    }

    // MARK: - visibility

    private var isEnabledInDefaults: Bool {
        // Default ON for v0.2.x — only honour the key if the user has
        // explicitly written it (UserDefaults.object(forKey:) returns
        // nil when never set, vs `bool(forKey:)` which always returns
        // false on missing).
        if let value = UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool {
            return value
        }
        return true
    }

    private func syncVisibility() {
        guard let player else { return }
        let isPlayingOrPaused = (player.state == .playing || player.state == .paused)
        let alwaysVisible = settings?.pillAlwaysVisible ?? false
        // Pill is visible when:
        //   • always-visible mode is ON (Lane 2 / v0.2.x feature), or
        //   • audio is playing/paused, or
        //   • the dispatcher is in the pre-audio loading window (Lane 1
        //     ~50ms responsiveness — AudioPlayer.isLoading clears in
        //     stop() and at first-chunk arrival).
        let shouldBeVisible = isEnabledInDefaults
            && (alwaysVisible || isPlayingOrPaused || player.isLoading)
        if shouldBeVisible {
            showWindow()
        } else {
            hideWindow()
        }
        // Push the always-visible flag into the view model so the
        // pill UI can render an idle state (bird + "Myna", no
        // waveform) when nothing is playing but the pill is still up.
        viewModel?.setAlwaysVisible(alwaysVisible)
    }

    private func ensureWindow() {
        if window != nil { return }
        guard let player, let settings else { return }
        let vm = PillViewModel(player: player, settings: settings, bridge: bridge)
        // Initialise the always-visible flag before SwiftUI first renders
        // so the idle layout doesn't flash on first show.
        vm.setAlwaysVisible(settings.pillAlwaysVisible)
        let view = PillView(viewModel: vm)
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        // Let the hosting view size itself based on intrinsic content.
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 64)

        let panel = FloatingPillWindow(contentView: hosting)
        self.window = panel
        self.hostingView = hosting
        self.viewModel = vm

        // Track expand/collapse to resize the window frame to fit.
        // When the user has positioned the pill we keep the origin
        // fixed and only resize the size component. Stored in
        // windowCancellables so resetPosition() (which recreates the
        // window) drops the subscription cleanly.
        vm.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.repositionWindow() }
            }
            .store(in: &windowCancellables)
    }

    private func showWindow() {
        ensureWindow()
        guard let window else { return }
        repositionWindow()
        // orderFrontRegardless because we don't want to activate Myna;
        // the .nonactivatingPanel style means this won't steal focus.
        window.orderFrontRegardless()
        window.alphaValue = 1
    }

    private func hideWindow() {
        guard let window else { return }
        window.alphaValue = 0
        window.orderOut(nil)
    }

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
    private func targetScreen() -> NSScreen? {
        Self.screenForCursor(
            NSEvent.mouseLocation,
            screens: NSScreen.screens
        )
    }

    private func repositionWindow() {
        guard let window, let screen = targetScreen() else { return }
        if window.isDragging {
            // Don't fight a live drag — AppKit owns the frame for the
            // duration. The drag-end notification will re-trigger us
            // if anything else needs to settle.
            return
        }

        // Size the panel to fit its content view.
        window.layoutIfNeeded()
        let fitting = hostingView?.fittingSize ?? window.frame.size
        let width = max(80, fitting.width)
        let height = max(Pill_minHeight, fitting.height)

        if window.hasUserPosition {
            // Resize in place around the current origin, but clamp
            // the frame to stay on a visible screen (display unplug
            // safety). If the saved origin lands off-screen, snap to
            // bottom-centre of the screen-under-cursor.
            var frame = window.frame
            frame.size = CGSize(width: width, height: height)
            if !isFrameOnAnyScreen(frame) {
                frame = bottomCenterFrame(on: screen, width: width, height: height)
            }
            window.setFrame(frame, display: true, animate: false)
            return
        }

        // Default position: bottom-centre of the screen-under-cursor.
        let target = bottomCenterFrame(on: screen, width: width, height: height)
        window.setFrame(target, display: true, animate: false)
    }

    private func bottomCenterFrame(
        on screen: NSScreen,
        width: CGFloat,
        height: CGFloat
    ) -> NSRect {
        let visible = screen.visibleFrame  // accounts for Dock/menu bar
        let x = visible.midX - width / 2
        let y = visible.minY + Self.bottomMargin
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func isFrameOnAnyScreen(_ frame: NSRect) -> Bool {
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

    private func handleScreenChange() {
        // Display arrangement changed (plug/unplug). If the user had
        // a custom position that's now off-screen we'll re-snap to a
        // visible screen via the off-screen check in repositionWindow.
        repositionWindow()
    }

    private func handleUserDrag() {
        // Nothing to do beyond the side-effects AppKit already
        // applied (autosaved frame + hasUserPosition=true). Send an
        // objectWillChange so any UI bound to the controller (e.g.
        // a future "pill is at custom position" indicator) refreshes.
        objectWillChange.send()
    }

    // MARK: - public API

    /// Forget the persisted pill position and snap back to
    /// bottom-centre of the screen-under-cursor. Wired to the
    /// "Reset pill position" action in the menu-bar popover.
    public func resetPosition() {
        // Clear AppKit's autosaved frame from UserDefaults so the
        // next launch also starts fresh.
        UserDefaults.standard.removeObject(forKey: FloatingPillFrame.defaultsKey)
        // Also clear under the raw autosave name in case AppKit
        // version changes its prefix scheme (defensive — currently
        // a no-op).
        UserDefaults.standard.removeObject(forKey: FloatingPillFrame.autosaveName)
        if let window {
            // Calling setFrameAutosaveName("") then re-setting it is
            // the documented way to drop AppKit's in-memory cache of
            // the autosave name; without it AppKit will rewrite the
            // key on the next move.
            window.setFrameAutosaveName("")
            // Reset our flag so the next reposition snaps to default.
            // We have to clear `hasUserPosition` by recreating the
            // window — there's no public setter. Cheap: tear down
            // and let showWindow() rebuild lazily.
            let wasVisible = window.alphaValue > 0
            window.orderOut(nil)
            self.window = nil
            self.hostingView = nil
            self.viewModel = nil
            // Drop per-window subscriptions so ensureWindow() can
            // re-install them against the fresh viewModel without
            // accumulating dead sinks.
            windowCancellables.removeAll()
            if wasVisible {
                showWindow()
            } else {
                // Build window in idle state so the next show uses
                // the default frame and re-installs the autosave.
                ensureWindow()
            }
        }
    }
}

/// Lifted from the design tokens in PillView (which are file-private
/// there). Keep small and out of view-model so the controller doesn't
/// have to import SwiftUI just for a number.
private let Pill_minHeight: CGFloat = 24
