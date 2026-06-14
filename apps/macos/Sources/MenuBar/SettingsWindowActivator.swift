// SettingsWindowActivator.swift — robustly bring the Settings window to
// the front as the key window.
//
// Opening the SwiftUI `Settings` scene from an LSUIElement / `.accessory`
// app (Myna has no Dock icon) does NOT reliably activate the app or make
// the Settings window key. On some machines the window opens *behind*
// whatever app is currently frontmost. Two user-visible bugs fall out of
// that single root cause:
//
//   1. "Clicking Settings opens it in the background somewhere" — the
//      user has to hunt for the window.
//   2. "The record-shortcut field doesn't work" — the KeyboardShortcuts
//      recorder captures a chord via a *local* NSEvent monitor that only
//      receives key events while the app is active AND the window is key.
//      A background / non-key Settings window means no keystrokes ever
//      reach the monitor, so nothing records — regardless of which
//      keyboard (built-in or external) the user presses.
//
// This helper force-activates the app and raises the Settings window to
// the front as the key window. It polls briefly because the window is
// created a few runloop ticks *after* the open is requested (both
// `SettingsLink` and `showSettingsWindow:` are asynchronous).
import AppKit

@MainActor
enum SettingsWindowActivator {
    /// SwiftUI's Settings scene assigns its window this identifier on
    /// macOS 13–15. We match it first, then fall back to a title heuristic
    /// so we keep working if Apple renames it in a future release.
    private static let swiftUISettingsWindowID = "com_apple_SwiftUI_Settings_window"

    /// Activate the app and bring the Settings window forward as key.
    /// Safe to call before the window exists — it retries on the main
    /// runloop until the window appears (or a short budget elapses).
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        raise(retriesLeft: 15)
    }

    private static func raise(retriesLeft: Int) {
        if let window = settingsWindow() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        guard retriesLeft > 0 else { return }
        // ~40ms × 15 ≈ 0.6s budget — long enough for SettingsLink to
        // materialise the window, short enough to feel instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            raise(retriesLeft: retriesLeft - 1)
        }
    }

    private static func settingsWindow() -> NSWindow? {
        // Prefer the SwiftUI Settings window by its stable identifier.
        if let byID = NSApp.windows.first(where: {
            $0.identifier?.rawValue == swiftUISettingsWindowID
        }) {
            return byID
        }
        // Fallback: a titled window whose title matches the localized
        // Settings/Preferences label. The menu-bar popover (borderless,
        // untitled) and the bird-label window are excluded by `.titled`.
        let settingsTitles = ["Settings", "Preferences"]
        return NSApp.windows.first { window in
            guard window.styleMask.contains(.titled) else { return false }
            return settingsTitles.contains { window.title.localizedCaseInsensitiveContains($0) }
        }
    }
}
