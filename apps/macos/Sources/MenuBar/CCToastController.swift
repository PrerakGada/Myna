// CCToastController.swift — owns the stack of CCToastWindow panels and
// reconciles them against the most recent /v2/registry/list snapshot.
// Per Sally's spec (03-ux-direction.md § 5):
//
//   • Up to 3 toasts visible, vertically stacked, 8px gaps, newest on top
//   • 4th+ collapses to "+N more" pill + menu bar badge count
//   • DND / Focus mode → route to submenu silently (no toast, no chime)
//   • Acknowledgement chime fires on appear (gated by SettingsViewModel.toastChimeEnabled)
//
// The controller is an @ObservableObject so the menu bar parent can
// react to the visible/overflow counts (drives the menu's "+N more"
// badge and the menu-bar icon badge count).
//
// IMPORTANT: this controller does NOT poll on its own; it expects
// MenuBarController to feed it `registry: [RegistryV2Item]` snapshots
// on every poll tick. That keeps the polling loop centralized.
import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
public final class CCToastController: ObservableObject {
    /// Maximum visible toasts at once. 4th+ overflow into the "+N more"
    /// pill on the top toast and the menu-bar badge count.
    public static let maxVisible = 3

    /// IDs we've already presented this session — keep them from
    /// re-toasting on every poll tick.
    private var presentedIds: Set<String> = []
    /// IDs the user has explicitly discarded — don't re-show even if
    /// they re-appear in the registry. (Daemon may retain the audio for
    /// the registry submenu but the user is done with it as a toast.)
    private var discardedIds: Set<String> = []

    /// Currently open toast windows, newest first.
    private(set) var windows: [CCToastWindow] = []

    /// Items hidden behind the "+N more" overflow chip (currently in
    /// the registry but not on screen). Drives the menu-bar badge.
    @Published public private(set) var overflowCount: Int = 0

    public weak var actions: CCToastActions?

    /// True iff macOS is currently in a Focus / Do Not Disturb mode.
    /// Cached for the duration of one ingest pass.
    private var focusModeActive: Bool = false

    public init() {}

    /// Apply the latest registry snapshot. New (id) items are presented
    /// as toasts; items that disappeared from the registry have their
    /// toasts dismissed; existing items get age refresh.
    public func ingest(registry: [RegistryV2Item], chimeEnabled: Bool) {
        let activeIds = Set(registry.map(\.id))

        // Clean up toasts whose backing item is gone (daemon decided
        // it's stale, or another client played it).
        windows.removeAll { window in
            if !activeIds.contains(window.item.id) {
                window.dismissAnimated()
                return true
            }
            return false
        }

        // Decide focus-mode posture for this batch. We check once per
        // ingest rather than per toast so reads stay cheap.
        focusModeActive = isFocusModeActive()

        // Enumerate brand-new items (newest first per registry order).
        let newItems = registry.filter { item in
            !presentedIds.contains(item.id) && !discardedIds.contains(item.id)
        }
        for item in newItems {
            presentedIds.insert(item.id)
            if focusModeActive {
                // Silent route — toast goes straight to "later" so it
                // surfaces in the menu-bar submenu only.
                continue
            }
            present(item: item, chimeEnabled: chimeEnabled)
        }

        recomputeOverflow(against: registry)
        repositionStack()
    }

    /// Drop all toasts (e.g. on app quit or focus mode entering
    /// mid-session). Items remain in the registry — only the windows go.
    public func dismissAll() {
        for window in windows { window.dismissAnimated() }
        windows.removeAll()
        overflowCount = 0
    }

    // MARK: - private

    private func present(item: RegistryV2Item, chimeEnabled: Bool) {
        let window = CCToastWindow(item: item)
        window.onPlay = { [weak self, weak window] in
            guard let self, let window else { return }
            self.actions?.play(item: window.item)
            self.dismissWindow(window, reason: .userLater)
        }
        window.onLater = { [weak self, weak window] in
            guard let self, let window else { return }
            self.dismissWindow(window, reason: .userLater)
        }
        window.onDismiss = { [weak self, weak window] reason in
            guard let self, let window else { return }
            switch reason {
            case .userDiscard:
                self.discardedIds.insert(window.item.id)
                self.actions?.discard(item: window.item)
            case .timeout, .userLater:
                break  // item stays in the submenu
            }
            self.dismissWindow(window, reason: reason)
        }
        windows.insert(window, at: 0)
        // Trim — if we just exceeded maxVisible, drop the oldest so the
        // newest gets the top slot.
        if windows.count > Self.maxVisible {
            let extra = windows.suffix(from: Self.maxVisible)
            for trimmed in extra { trimmed.dismissAnimated() }
            windows = Array(windows.prefix(Self.maxVisible))
        }
        let suppressMotion = PowerMonitor.shared.shouldSuppressAnimation
        window.showAnimated(animated: !suppressMotion)
        if chimeEnabled {
            Earcon.shared.play(.toastReady)
        }
    }

    private func dismissWindow(_ window: CCToastWindow, reason: CCToastWindow.DismissReason) {
        windows.removeAll { $0 === window }
        window.dismissAnimated()
        repositionStack()
    }

    private func repositionStack() {
        let screen = NSScreen.main
        for (idx, window) in windows.enumerated() {
            window.updateStackIndex(idx, on: screen)
        }
    }

    private func recomputeOverflow(against registry: [RegistryV2Item]) {
        // Pending registry size minus what we currently show on screen
        // gives the +N count. We don't subtract discarded — those don't
        // count toward the menu-bar badge either.
        let visible = windows.count
        let pending = registry.count
        overflowCount = max(0, pending - visible)
    }

    /// macOS doesn't expose Focus mode directly; the documented proxy is
    /// `UNUserNotificationCenter.current().getNotificationSettings { … }`
    /// (which returns `.notificationCenterSetting == .disabled` while
    /// Focus is on) plus checking `NSWorkspace.shared.notificationCenter`
    /// hints. For Track A v0.2 we use a best-effort synchronous read of
    /// the saved Focus state via private CoreFoundation — but that's
    /// fragile; the conservative default is "assume Focus is OFF unless
    /// we have a clear signal" so users don't lose toasts to a false
    /// positive.
    ///
    /// IMPORTANT: this returns the cached value from the last async
    /// query (refreshed every 5s). Initial value is `false`; the first
    /// query result lands within ~30ms.
    private static var cachedFocusActive: Bool = false
    private static var lastFocusQuery: Date = .distantPast
    private static var focusQueryInFlight: Bool = false

    private func isFocusModeActive() -> Bool {
        if Date().timeIntervalSince(Self.lastFocusQuery) > 5 && !Self.focusQueryInFlight {
            Self.focusQueryInFlight = true
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                // `.notificationCenterSetting == .disabled` is the documented
                // proxy for DND mode. We extract the Sendable Bool *before*
                // hopping back to @MainActor (UNNotificationSettings itself
                // isn't Sendable under Swift 6 strict concurrency).
                let isDisabled = settings.notificationCenterSetting == .disabled
                Task { @MainActor in
                    Self.cachedFocusActive = isDisabled
                    Self.lastFocusQuery = Date()
                    Self.focusQueryInFlight = false
                }
            }
        }
        return Self.cachedFocusActive
    }
}

/// Callbacks the controller invokes when the user interacts with a
/// toast. Implemented by MenuBarController so the play call goes to
/// DaemonClient.registryPlayV2 on the actor side.
@MainActor
public protocol CCToastActions: AnyObject {
    func play(item: RegistryV2Item)
    func discard(item: RegistryV2Item)
}
