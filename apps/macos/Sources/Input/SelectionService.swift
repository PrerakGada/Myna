// SelectionService.swift — capture the user's currently-selected text
// by simulating Cmd+C and reading NSPasteboard. Saves and restores the
// prior pasteboard contents so we don't clobber the user's clipboard.
//
// Both the pasteboard and the key-event mechanism are protocol-injected
// so tests can run without touching real system state.
//
// Permissions: real Cmd+C posting via CGEvent requires Accessibility.
// The default implementation degrades gracefully if posting fails
// (returns nil), so the UI can show a "grant accessibility" prompt.
import AppKit
import Foundation

/// Abstract over NSPasteboard so tests can inject a fake.
public protocol PasteboardProtocol: AnyObject {
    var pasteboardString: String? { get set }
    func saveSnapshot() -> [NSPasteboardItem]
    func restore(_ items: [NSPasteboardItem])
    func clearContents()
}

/// Abstract over CGEvent.post — the actual Cmd+C synthesizer. Tests
/// inject a stub that returns true/false instead of synthesizing real
/// keypresses (which would require accessibility on the test host).
public protocol KeyPostingProtocol: Sendable {
    /// Returns true if the simulated keypress was successfully posted.
    func postCmdC() -> Bool
}

public final class NSPasteboardAdapter: PasteboardProtocol, @unchecked Sendable {
    private let underlying: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.underlying = pasteboard
    }

    public var pasteboardString: String? {
        get { underlying.string(forType: .string) }
        set {
            underlying.clearContents()
            if let value = newValue {
                underlying.setString(value, forType: .string)
            }
        }
    }

    public func saveSnapshot() -> [NSPasteboardItem] {
        guard let items = underlying.pasteboardItems else { return [] }
        return items.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    public func restore(_ items: [NSPasteboardItem]) {
        underlying.clearContents()
        if !items.isEmpty {
            underlying.writeObjects(items)
        }
    }

    public func clearContents() {
        underlying.clearContents()
    }
}

public struct CGEventKeyPoster: KeyPostingProtocol {
    public init() {}

    public func postCmdC() -> Bool {
        // 0x08 is the keycode for 'c' on US ANSI; layout-independent
        // because we send with the command flag.
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let downEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
            let upEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        else {
            return false
        }
        downEvent.flags = .maskCommand
        upEvent.flags = .maskCommand
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
        return true
    }
}

/// Captures the currently-selected text from the frontmost application.
public final class SelectionService: @unchecked Sendable {
    private let pasteboard: PasteboardProtocol
    private let keyPoster: KeyPostingProtocol
    /// How long to wait between posting Cmd+C and reading the pasteboard.
    /// Empirically 120ms is the smallest window where every tested app
    /// (Safari, Chrome, Slack, Mail, etc.) has finished its copy handler.
    public let copyWaitNanos: UInt64
    /// Returns true while the user is still physically holding modifier keys.
    /// Injected so tests stay deterministic; the default reads the live
    /// hardware modifier state via CGEventSource. See `captureSelectedText`
    /// for why this matters (synthetic Cmd+C pollution by the hotkey combo).
    private let modifiersHeld: @Sendable () -> Bool
    private let log = Log(.app)

    public init(
        pasteboard: PasteboardProtocol = NSPasteboardAdapter(),
        keyPoster: KeyPostingProtocol = CGEventKeyPoster(),
        copyWaitNanos: UInt64 = 120_000_000,
        modifiersHeld: @escaping @Sendable () -> Bool = {
            let f = CGEventSource.flagsState(.combinedSessionState)
            return f.contains(.maskCommand) || f.contains(.maskShift)
                || f.contains(.maskAlternate) || f.contains(.maskControl)
        }
    ) {
        self.pasteboard = pasteboard
        self.keyPoster = keyPoster
        self.copyWaitNanos = copyWaitNanos
        self.modifiersHeld = modifiersHeld
    }

    /// Capture the user's selected text. Returns nil if no text was
    /// selected, or if the key-posting mechanism failed (e.g., the app
    /// hasn't been granted Accessibility yet).
    ///
    /// **@MainActor is load-bearing, not decoration.** `NSPasteboard` is
    /// AppKit and is not thread-safe. This method used to be nonisolated
    /// `async`, so despite being called from the @MainActor AppDispatcher it
    /// ran on the cooperative pool — every `saveSnapshot()` / `restore()` /
    /// `pasteboardString` touched NSPasteboard off-main. Repeating a trackpad
    /// gesture overlapped two captures, they mutated the pasteboard's internal
    /// NSConcreteMapTable concurrently, and the resulting uncaught ObjC
    /// exception aborted the process:
    ///
    ///     NSPasteboard.pasteboardItems → objc_exception_throw → abort()
    ///     thread: com.apple.root.user-initiated-qos.cooperative
    ///
    /// (Crash on 0.4.5 / macOS 26.5.2, 2026-08-05.) The `await`s below are
    /// suspension points, so main-actor isolation does NOT block the UI.
    @MainActor
    public func captureSelectedText() async -> String? {
        let snapshot = pasteboard.saveSnapshot()
        pasteboard.clearContents()
        // Restore the user's prior pasteboard contents on EVERY exit path —
        // including Task cancellation during the 120ms copy-wait sleep, which
        // would otherwise leave the user with an empty clipboard.
        // Per AUDIT_REPORT.md Security 🟡 #3 / Lane A 🟡 #5.
        defer { pasteboard.restore(snapshot) }

        // Wait (briefly, bounded) for the hotkey's own modifiers to lift
        // before synthesizing Cmd+C. The read shortcut is a modifier combo
        // (default ⌘⌥⇧S) fired on keyDown, so the keys are still physically
        // down when we get here; a Cmd+C posted now arrives as ⌘⌥⇧C, which no
        // app treats as Copy — the pasteboard stays empty and we report
        // "no text captured". Whether the user has lifted the keys by now is a
        // race → the intermittent "sometimes it reads, sometimes it doesn't".
        // No-op for gesture / URL-scheme triggers (no modifiers held) and tests.
        var waitedForMods: UInt64 = 0
        let modStep: UInt64 = 15_000_000        // 15ms
        let modCap: UInt64 = 600_000_000        // give up after 600ms, try anyway
        while modifiersHeld(), waitedForMods < modCap {
            try? await Task.sleep(nanoseconds: modStep)
            waitedForMods += modStep
        }

        // Which app the synthetic ⌘C will actually land in. Logged on failure
        // because "no text captured" behaves very differently per app and the
        // old single warning couldn't tell the cases apart.
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        let posted = keyPoster.postCmdC()
        guard posted else {
            // CGEvent creation/posting failed outright — almost always a
            // missing Accessibility grant for THIS binary.
            log.warn("capture: Cmd+C post failed (front=\(frontApp)) — check Accessibility")
            return nil
        }
        try? await Task.sleep(nanoseconds: copyWaitNanos)
        let captured = pasteboard.pasteboardString
        // Trim and treat empty as "no selection".
        guard let value = captured?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            // ⌘C was posted but the pasteboard is still empty after the wait.
            // Either nothing was selected, or the app didn't act on a synthetic
            // ⌘C (some apps consult the real hardware modifier state rather
            // than the event's flags — we never press the physical ⌘ key).
            log.warn(
                "capture: pasteboard empty \(copyWaitNanos / 1_000_000)ms after Cmd+C "
                + "(front=\(frontApp)) — no selection, or app ignored synthetic copy")
            return nil
        }
        log.info("capture: \(value.count) chars from \(frontApp)")
        return value
    }
}
