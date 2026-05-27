// PillController.swift — lifecycle owner for the floating pill.
//
// Responsibilities:
//   - lazily create the FloatingPillWindow + SwiftUI hosting view
//   - show/hide the window based on AudioPlayer.state
//   - reposition to bottom-center of the active screen on:
//       * playback start
//       * pill expand/collapse (the frame size changes)
//       * NSApplication.didChangeScreenParametersNotification
//       * NSWorkspace.didActivateApplicationNotification
//   - respect the user's "Show floating pill while speaking" toggle
//     stored under `dev.myna.app.showFloatingPill` (default true)
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

    /// Margin from the bottom edge of the screen (above the Dock if
    /// it's pinned to bottom). 28pt mirrors typical macOS HUD spacing.
    private static let bottomMargin: CGFloat = 28

    private var player: AudioPlayer?
    private var settings: SettingsViewModel?
    private let bridge: PillBridge

    private var window: FloatingPillWindow?
    private var viewModel: PillViewModel?
    private var hostingView: NSHostingView<PillView>?
    private var cancellables = Set<AnyCancellable>()
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
        guard cancellables.isEmpty, let player else { return }

        // Player state drives visibility.
        player.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncVisibility()
            }
            .store(in: &cancellables)

        // Screen / front-app changes re-position the pill.
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.repositionWindow() }
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

        // Apply the current state immediately.
        syncVisibility()
    }

    /// Stop observing and tear down the window. Called from
    /// AppDelegate.applicationWillTerminate.
    public func stop() {
        cancellables.removeAll()
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
        let shouldBeVisible = isEnabledInDefaults
            && (player.state == .playing || player.state == .paused)
        if shouldBeVisible {
            showWindow()
        } else {
            hideWindow()
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        guard let player, let settings else { return }
        let vm = PillViewModel(player: player, settings: settings, bridge: bridge)
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
        vm.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.repositionWindow() }
            }
            .store(in: &cancellables)
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

    /// Compute the target screen: the screen that currently contains
    /// the frontmost application's main window. Falls back to
    /// `NSScreen.main` (cursor screen) and finally the first screen.
    private func targetScreen() -> NSScreen? {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let appWindowBounds = frontmostWindowBounds(for: frontApp) {
            // Pick whichever screen contains the largest portion of
            // the front app's main window.
            let screens = NSScreen.screens
            let best = screens.max { lhs, rhs in
                intersectionArea(lhs.frame, appWindowBounds)
                    < intersectionArea(rhs.frame, appWindowBounds)
            }
            if let best { return best }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        guard !r.isNull else { return 0 }
        return r.width * r.height
    }

    /// Best-effort: read the front app's main window bounds via the
    /// Accessibility API. May be nil if the app doesn't expose it or
    /// we lack Accessibility permission; the caller falls back.
    private func frontmostWindowBounds(for app: NSRunningApplication) -> CGRect? {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement], let first = windows.first else {
            return nil
        }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(first, kAXSizeAttribute as CFString, &sizeRef)
        guard let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // AXValueGetValue returns false on type mismatch; both calls
        // are required.
        // swiftlint:disable force_cast
        let posOK = AXValueGetValue(posVal as! AXValue, .cgPoint, &position)
        let sizeOK = AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        guard posOK, sizeOK else { return nil }
        // AX coordinates are top-left origin in *flipped* (screen)
        // space — i.e. y=0 is at the top of the primary screen. We
        // convert to AppKit's bottom-left coordinate space below.
        return CGRect(origin: position, size: size)
    }

    private func repositionWindow() {
        guard let window, let screen = targetScreen() else { return }
        // Size the panel to fit its content view.
        window.layoutIfNeeded()
        if let host = hostingView {
            let fitting = host.fittingSize
            // Clamp to sane minimums to avoid 0-size frames during
            // SwiftUI transitions.
            let width = max(80, fitting.width)
            let height = max(Pill_minHeight, fitting.height)
            var frame = window.frame
            frame.size = CGSize(width: width, height: height)
            window.setFrame(frame, display: false, animate: false)
        }

        let visible = screen.visibleFrame  // accounts for Dock/menu bar
        let frame = window.frame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + Self.bottomMargin
        let target = NSRect(x: x, y: y, width: frame.width, height: frame.height)
        window.setFrame(target, display: true, animate: false)
    }
}

/// Lifted from the design tokens in PillView (which are file-private
/// there). Keep small and out of view-model so the controller doesn't
/// have to import SwiftUI just for a number.
private let Pill_minHeight: CGFloat = 24
