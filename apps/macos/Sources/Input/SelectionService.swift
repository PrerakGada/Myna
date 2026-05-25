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

    public init(
        pasteboard: PasteboardProtocol = NSPasteboardAdapter(),
        keyPoster: KeyPostingProtocol = CGEventKeyPoster(),
        copyWaitNanos: UInt64 = 120_000_000
    ) {
        self.pasteboard = pasteboard
        self.keyPoster = keyPoster
        self.copyWaitNanos = copyWaitNanos
    }

    /// Capture the user's selected text. Returns nil if no text was
    /// selected, or if the key-posting mechanism failed (e.g., the app
    /// hasn't been granted Accessibility yet).
    public func captureSelectedText() async -> String? {
        let snapshot = pasteboard.saveSnapshot()
        pasteboard.clearContents()
        // Restore the user's prior pasteboard contents on EVERY exit path —
        // including Task cancellation during the 120ms copy-wait sleep, which
        // would otherwise leave the user with an empty clipboard.
        // Per AUDIT_REPORT.md Security 🟡 #3 / Lane A 🟡 #5.
        defer { pasteboard.restore(snapshot) }

        let posted = keyPoster.postCmdC()
        guard posted else { return nil }
        try? await Task.sleep(nanoseconds: copyWaitNanos)
        let captured = pasteboard.pasteboardString
        // Trim and treat empty as "no selection".
        guard let value = captured?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
