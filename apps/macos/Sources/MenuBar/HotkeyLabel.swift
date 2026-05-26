// HotkeyLabel.swift — render a KeyboardShortcuts.Shortcut as a short
// display string suitable for the menu bar transport rows
// (e.g. "⌃⌥⇧S", "⌘→"). v0.2 / S06.
//
// We delegate the actual glyph rendering to KeyboardShortcuts'
// `Shortcut.description` (which produces "⌥⇧⌘S" via the same code path
// the library uses for its shortcut-recorder UI). This is the
// canonical macOS menu-row form, so we don't reinvent the
// modifier-glyph table here.
//
// IMPORTANT: we read the *current* shortcut for each action on every
// call, not at register time. If the user rebinds a shortcut via the
// Hotkeys tab, the menu reflects the new binding the next time the
// popover opens. Per S06 AC #4.
import Foundation
import KeyboardShortcuts

@MainActor
public enum HotkeyLabel {
    /// Pretty single-line glyph cluster for the given action's current
    /// binding, or nil if no shortcut is configured.
    ///
    /// Examples: "⌥⇧⌘S", "⌥⌘.", "⌘→", or nil for unbound.
    public static func display(for action: HotkeyAction) -> String? {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: action.name) else {
            return nil
        }
        return display(shortcut: shortcut)
    }

    /// Render the modifier glyph cluster + key glyph from a Shortcut.
    /// Exposed for tests.
    public static func display(shortcut: KeyboardShortcuts.Shortcut) -> String {
        // KeyboardShortcuts.Shortcut.description is the canonical
        // macOS menu-row form (e.g. "⌥⇧⌘S"). It's @MainActor-isolated;
        // we mirror that on this helper.
        shortcut.description
    }
}
