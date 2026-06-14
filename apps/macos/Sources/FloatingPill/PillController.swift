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
import QuartzCore
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
    /// Weak — app-lifetime singleton supplying recents + the replay hook.
    private weak var menuController: MenuBarController?
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

    /// Pending hover-out collapse work. Cancelled on re-entry so a fast
    /// cursor wiggle out-and-back doesn't flash the pill collapsed.
    private var hoverCollapseWork: DispatchWorkItem?
    /// Hover-out grace period. Wispr ~500ms; 600ms feels forgiving on a small
    /// target without making the pill feel sticky.
    private static let hoverCollapseDelay: TimeInterval = 0.6

    /// Pending Claude-output prompt (the newest unhandled CC item). The pill
    /// owns this — the top-right toast is suppressed while the pill is on.
    private var pendingPrompt: RegistryV2Item?
    /// CC ids the user has played/dismissed this session, filtered so a handled
    /// item doesn't re-prompt on the next registry poll.
    private var ccHandledIds: Set<String> = []
    /// Auto-dismiss the in-pill prompt after a grace period.
    private var promptAutoDismissWork: DispatchWorkItem?
    private static let promptAutoDismissDelay: TimeInterval = 8

    /// Debounce for display-configuration changes — sleep/wake and plug/unplug
    /// emit storms of screen-params notifications, sometimes with a transient
    /// degenerate screen set.
    private var screenChangeWork: DispatchWorkItem?
    private static let screenChangeDebounce: TimeInterval = 0.2

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
    public func attach(
        player: AudioPlayer,
        settings: SettingsViewModel,
        menuController: MenuBarController? = nil
    ) {
        guard self.player == nil else { return }
        self.player = player
        self.settings = settings
        self.menuController = menuController
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

        // Claude-output prompts — the pill owns these (the top-right toast is
        // suppressed when the pill is enabled). Observe the menu bar's pending
        // CC registry and surface the newest unhandled item in-pill.
        menuController?.$ccPending
            .receive(on: RunLoop.main)
            .sink { [weak self] items in self?.handleCCPending(items) }
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
        hoverCollapseWork?.cancel()
        hoverCollapseWork = nil
        promptAutoDismissWork?.cancel()
        promptAutoDismissWork = nil
        screenChangeWork?.cancel()
        screenChangeWork = nil
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
            && (alwaysVisible || isPlayingOrPaused || player.isLoading || pendingPrompt != nil)
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
        let vm = PillViewModel(
            player: player, settings: settings, bridge: bridge,
            menuController: menuController
        )
        // Initialise the always-visible flag before SwiftUI first renders
        // so the idle layout doesn't flash on first show.
        vm.setAlwaysVisible(settings.pillAlwaysVisible)
        let view = PillView(viewModel: vm)
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        // Let the hosting view size itself based on intrinsic content.
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 64)

        // Wrap the SwiftUI host in an NSTrackingArea-owning view so hover is
        // detected at the AppKit layer (reliable even though the panel is
        // never key — SwiftUI .onHover drops mouseExited at speed). Tracking
        // is enter/exit only and never consumes a click, so the window's
        // mouseDown tap/drag path is unaffected.
        let tracking = PillTrackingView(frame: hosting.frame)
        tracking.addSubview(hosting)
        tracking.onHoverChange = { [weak self] entered in
            self?.handleHoverChange(entered)
        }

        let panel = FloatingPillWindow(contentView: tracking)
        // Route clicks on the pill background to the pin toggle. The
        // SwiftUI `.onTapGesture { togglePin() }` inside PillView never
        // fires once mouseDown is intercepted at the window — see the
        // mouseDown comment block in FloatingPillWindow.swift — so we
        // hand the tap off here.
        panel.onBackgroundTap = { [weak vm] in
            vm?.togglePin()
        }
        self.window = panel
        self.hostingView = hosting
        self.viewModel = vm

        // Push any pending Claude-output prompt into the fresh view-model and
        // wire its buttons back to the controller's handled-id bookkeeping.
        vm.setPrompt(pendingPrompt)
        vm.onPlayPrompt = { [weak self] item in self?.playPrompt(item) }
        vm.onDismissPrompt = { [weak self] item in self?.dismissPrompt(item) }

        // Resize/animate the panel whenever the layout footprint changes
        // (collapsed ↔ expanded ↔ processing). dropFirst skips the initial
        // value — showWindow() does the first placement. Stored in
        // windowCancellables so it's torn down cleanly with the window.
        vm.$layout
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.repositionWindow(forLayoutChange: true) }
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

    // MARK: - hover

    /// Hover changed (from PillTrackingView's NSTrackingArea). Entering
    /// cancels any pending collapse and expands immediately; exiting schedules
    /// a collapse after a 600ms grace so a fast cursor wiggle out-and-back
    /// doesn't flash the pill collapsed. Re-entry cancels the pending work.
    /// (Pinned pills resolve to .expanded regardless, so a stray timer firing
    /// is harmless.)
    private func handleHoverChange(_ entered: Bool) {
        guard let viewModel else { return }
        if entered {
            hoverCollapseWork?.cancel()
            hoverCollapseWork = nil
            viewModel.setHovering(true)
        } else {
            hoverCollapseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.hoverCollapseWork = nil
                self?.viewModel?.setHovering(false)
            }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.hoverCollapseDelay, execute: work)
        }
    }

    // MARK: - Claude-output prompt

    private func handleCCPending(_ items: [RegistryV2Item]) {
        let enabled = settings?.ccToastsEnabled ?? true
        let next = enabled ? items.first { !ccHandledIds.contains($0.id) } : nil
        guard next?.id != pendingPrompt?.id else { return }
        pendingPrompt = next
        viewModel?.setPrompt(next)
        schedulePromptAutoDismiss()
        syncVisibility()
    }

    private func schedulePromptAutoDismiss() {
        promptAutoDismissWork?.cancel()
        promptAutoDismissWork = nil
        guard let item = pendingPrompt else { return }
        let work = DispatchWorkItem { [weak self] in self?.markPromptHandled(item) }
        promptAutoDismissWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.promptAutoDismissDelay, execute: work)
    }

    /// Play the prompt through the IN-PROCESS player (so the pill's transport
    /// controls it), reusing the .mynaReplayRecent → AppDispatcher synth wire.
    private func playPrompt(_ item: RegistryV2Item) {
        NotificationCenter.default.post(
            name: .mynaReplayRecent, object: nil, userInfo: ["title": item.title])
        markPromptHandled(item)
    }

    private func dismissPrompt(_ item: RegistryV2Item) {
        markPromptHandled(item)
    }

    private func markPromptHandled(_ item: RegistryV2Item) {
        ccHandledIds.insert(item.id)
        promptAutoDismissWork?.cancel()
        promptAutoDismissWork = nil
        guard pendingPrompt?.id == item.id else { return }
        pendingPrompt = nil
        viewModel?.setPrompt(nil)
        syncVisibility()
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

    private func repositionWindow(forLayoutChange: Bool = false) {
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

    private func handleUserDrag() {
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

    // MARK: - public API

    /// Forget the persisted pill position and snap back to
    /// bottom-centre of the screen-under-cursor. Wired to the
    /// "Reset pill position" action in the menu-bar popover.
    public func resetPosition() {
        // Forget the new (display, fractional-offset) anchor…
        PillAnchorStore.clear()
        // …and the legacy AppKit autosave keys, so a machine upgrading
        // from a v0.2.x install (which used setFrameAutosaveName) also
        // starts fresh rather than restoring a stale absolute origin.
        UserDefaults.standard.removeObject(forKey: FloatingPillFrame.defaultsKey)
        UserDefaults.standard.removeObject(forKey: FloatingPillFrame.autosaveName)
        // With the anchor gone, repositionWindow snaps back to
        // bottom-centre of the screen under the cursor. No window
        // teardown needed any more — positioning keys off the anchor
        // store, not a per-window flag.
        repositionWindow()
    }
}

/// Lifted from the design tokens in PillView (file-private there). Keep
/// small and out of the view-model so the controller doesn't have to
/// import SwiftUI just for a number.
private let pillMinHeight: CGFloat = 24
