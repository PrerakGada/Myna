// HotkeyManager.swift — wraps the KeyboardShortcuts SPM library and
// exposes a single `register(handlers:)` API for the five default
// Myna actions. Defaults exactly mirror the v1 hammerspoon/myna.lua
// DEFAULT_BINDINGS so users migrating from v1 see no change in
// behaviour.
//
// Tests exercise the library's `system` recording path without
// touching real global hotkeys; the library exposes
// `KeyboardShortcuts.postEvent(_:)` (via its own `MockKeyEvent` API in
// testing builds) but the public API doesn't guarantee that, so our
// tests verify (1) defaults match v1 and (2) handler registration
// stores the closure in the manager (we directly invoke the stored
// handler in tests, rather than firing a real system event).
import Foundation
import KeyboardShortcuts

/// Identifier strings must match v1 keybindings.json for compatibility.
extension KeyboardShortcuts.Name {
    public static let speakSelectionFull = Self(
        "speakSelectionFull",
        default: .init(.s, modifiers: [.command, .option, .shift])
    )
    public static let speakSelectionSummary = Self(
        "speakSelectionSummary",
        default: .init(.a, modifiers: [.command, .option, .shift])
    )
    public static let readChromeArticle = Self(
        "readChromeArticle",
        default: .init(.r, modifiers: [.command, .option, .shift])
    )
    public static let pauseResume = Self(
        "pauseResume",
        default: .init(.space, modifiers: [.command, .option, .shift])
    )
    public static let stop = Self(
        "stop",
        default: .init(.period, modifiers: [.command, .option, .shift])
    )

    /// All five Myna shortcut names, in declaration order.
    public static let allMynaShortcuts: [KeyboardShortcuts.Name] = [
        .speakSelectionFull,
        .speakSelectionSummary,
        .readChromeArticle,
        .pauseResume,
        .stop,
    ]
}

/// The semantic actions the hotkeys map to. Strings match v1 keybindings.json.
public enum HotkeyAction: String, CaseIterable, Sendable {
    case speakSelectionFull = "speak_selection_full"
    case speakSelectionSummary = "speak_selection_summary"
    case readChromeArticle = "read_chrome_article"
    case pauseResume = "pause_resume"
    case stop

    public var name: KeyboardShortcuts.Name {
        switch self {
        case .speakSelectionFull: return .speakSelectionFull
        case .speakSelectionSummary: return .speakSelectionSummary
        case .readChromeArticle: return .readChromeArticle
        case .pauseResume: return .pauseResume
        case .stop: return .stop
        }
    }
}

@MainActor
public final class HotkeyManager {
    public typealias Handler = @MainActor () -> Void

    private var handlers: [HotkeyAction: Handler] = [:]
    private var registered: Bool = false

    public init() {}

    /// Register handlers for each action. Pass nil for actions you don't
    /// want bound. Subsequent calls replace prior handlers (the
    /// KeyboardShortcuts library is idempotent on re-register).
    public func register(handlers: [HotkeyAction: Handler]) {
        self.handlers = handlers
        for (action, handler) in handlers {
            KeyboardShortcuts.onKeyDown(for: action.name) {
                Task { @MainActor in handler() }
            }
        }
        registered = true
    }

    /// Disable all registered handlers — both removes them from the
    /// library and forgets them locally.
    public func disableAll() {
        for action in HotkeyAction.allCases {
            KeyboardShortcuts.disable(action.name)
        }
        handlers.removeAll()
        registered = false
    }

    /// Test-only: invoke the locally-stored handler as if the user had
    /// pressed the corresponding shortcut. Production code never calls
    /// this; the system event loop drives real invocations.
    public func invokeForTesting(_ action: HotkeyAction) -> Bool {
        guard let handler = handlers[action] else { return false }
        handler()
        return true
    }

    /// Test-only: true iff `register(handlers:)` has been called and not
    /// subsequently disabled.
    public var isRegisteredForTesting: Bool { registered }
}
