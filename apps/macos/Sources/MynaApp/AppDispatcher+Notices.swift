// AppDispatcher+Notices.swift — what an empty read tells the user.
//
// Split out of AppDispatcher.swift to keep that file under the length
// limit; nothing here touches dispatcher state.
import AppKit

extension AppDispatcher {
    /// Terminal emulators that run full-screen TUIs. While a TUI has mouse
    /// reporting on, a drag is delivered to the TUI instead of creating a
    /// *terminal* selection — so ⌘C has nothing to copy and the read comes
    /// back empty. Holding ⌥ forces a native selection, which is the one
    /// piece of advice worth surfacing here.
    static let terminalBundleIds: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "io.alacritty",
        "com.mitchellh.ghostty",
    ]

    /// Explain an empty read instead of failing silently. Split out of
    /// `speakSelection` so that method stays under the body-length limit.
    static func presentNoSelectionNotice(on menu: MenuBarController?) {
        guard let menu else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let isTerminal = front?.bundleIdentifier.map(terminalBundleIds.contains) ?? false
        let name = front?.localizedName ?? "that app"
        // Without Accessibility neither capture path can work, and the
        // Services menu is the way in that needs no permission.
        guard AXIsProcessTrusted() else {
            menu.showNotice(
                title: "Myna can't see your selection",
                hint: "The read shortcut needs Accessibility permission. Without it, "
                    + "right-click the selection and choose Services ▸ Read with Myna."
            )
            return
        }
        menu.showNotice(
            title: "Nothing selected to read",
            hint: isTerminal
                ? "Myna couldn't find selected text in \(name). Inside a "
                    + "full-screen app like Claude Code, hold ⌥ while dragging to select."
                : "Myna couldn't find selected text in \(name)."
        )
    }
}
