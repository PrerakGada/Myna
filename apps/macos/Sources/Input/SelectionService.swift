// SelectionService.swift — capture the user's currently-selected text.
//
// Two ways, tried in order (SelectionCaptureMode.automatic):
//   1. Accessibility: ask the focused element for its selected text
//      (AXSelectionReader). The clipboard is never touched.
//   2. Copy: simulate Cmd+C and read NSPasteboard, saving and restoring the
//      prior pasteboard contents so we don't clobber the user's clipboard.
// "Copy only" skips step 1, for an app whose AX answer turns out wrong.
// The Services menu ("Read with Myna") is a third way in that bypasses
// this file entirely: the requesting app hands the text over itself.
//
// The AX reader, the pasteboard and the key-event mechanism are all
// protocol-injected so tests can run without touching real system state.
//
// Permissions: both AX reads and real Cmd+C posting via CGEvent require
// Accessibility. Without it both degrade gracefully (returns nil), so the
// UI can show a "grant accessibility" prompt.
import AppKit
import Foundation

/// How the read shortcut captures the selection. Persisted as its raw value
/// under `dev.myna.app.selectionCapture`.
public enum SelectionCaptureMode: String, CaseIterable, Sendable {
    /// Accessibility first; synthetic ⌘C when AX has nothing.
    case automatic
    /// Always synthetic ⌘C — the pre-AX behaviour.
    case copyOnly = "copy"

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .copyOnly: return "Copy only"
        }
    }
}

/// Which path produced the text. Logged on every read — never the text.
public enum SelectionCapturePath: String, Sendable {
    case ax
    case copy
    case service
}

public struct CapturedSelection: Equatable, Sendable {
    public let text: String
    public let path: SelectionCapturePath

    public init(text: String, path: SelectionCapturePath) {
        self.text = text
        self.path = path
    }
}

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
    private let axReader: SelectionTextReading
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
        axReader: SelectionTextReading = AXSelectionReader(),
        pasteboard: PasteboardProtocol = NSPasteboardAdapter(),
        keyPoster: KeyPostingProtocol = CGEventKeyPoster(),
        copyWaitNanos: UInt64 = 120_000_000,
        modifiersHeld: @escaping @Sendable () -> Bool = {
            let f = CGEventSource.flagsState(.combinedSessionState)
            return f.contains(.maskCommand) || f.contains(.maskShift)
                || f.contains(.maskAlternate) || f.contains(.maskControl)
        }
    ) {
        self.axReader = axReader
        self.pasteboard = pasteboard
        self.keyPoster = keyPoster
        self.copyWaitNanos = copyWaitNanos
        self.modifiersHeld = modifiersHeld
    }

    /// Capture the user's selected text, and say which path produced it.
    /// Returns nil if neither path found any text.
    ///
    /// In `.automatic` mode the AX read runs first. It needs no modifier
    /// wait (it doesn't send keys), so when it works the read starts sooner
    /// than a ⌘C capture could. Anything short of real text — an AX error,
    /// no focused element, an empty or whitespace-only selection, or the
    /// deadline passing — falls through to the ⌘C path, unchanged.
    ///
    /// @MainActor for the same reason as `captureByCopying`. The AX read
    /// itself is awaited, and runs on AXSelectionReader's own queue.
    @MainActor
    public func capture(mode: SelectionCaptureMode) async -> CapturedSelection? {
        // The app the read is aimed at. Logged on every outcome because
        // capture behaves very differently per app.
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        if mode == .automatic {
            let started = DispatchTime.now()
            let outcome = await axReader.readSelectedText()
            let millis = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            switch outcome {
            case .text(let raw) where !raw.isBlank:
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                log.info("capture: path=ax chars=\(value.count) front=\(frontApp) (\(millis)ms)")
                return CapturedSelection(text: value, path: .ax)
            case .text:
                log.info("capture: ax found no selected text (front=\(frontApp), \(millis)ms), trying copy")
            case .unavailable(let reason):
                log.info("capture: ax unavailable [\(reason)] (front=\(frontApp), \(millis)ms), trying copy")
            case .timedOut:
                log.warn("capture: ax timed out after \(millis)ms (front=\(frontApp)), trying copy")
            }
        }
        guard let text = await captureByCopying(frontApp: frontApp) else { return nil }
        return CapturedSelection(text: text, path: .copy)
    }

    /// Capture by synthesizing ⌘C. Returns nil if no text was selected, or
    /// if the key-posting mechanism failed (e.g., the app hasn't been
    /// granted Accessibility yet).
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
    private func captureByCopying(frontApp: String) async -> String? {
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
        log.info("capture: path=copy chars=\(value.count) front=\(frontApp)")
        return value
    }
}
