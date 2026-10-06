// MenuBarActions.swift — the small surface the popover needs from the
// app's dispatcher, plus the clipboard probe behind the "Read clipboard"
// action.
//
// Why a protocol rather than a direct AppDispatcher reference: AppDelegate
// builds the dispatcher first and the menu controller second, and the
// dispatcher already holds a weak back-reference to the controller. Naming
// the dependency keeps that pair testable (a spy can stand in) and stops
// the menu layer from reaching into the whole dispatch stack.
//
// Note on what is deliberately NOT here: "speak selection". Opening the
// popover makes Myna frontmost, and SelectionService captures with a
// synthetic ⌘C aimed at the frontmost app — so a "Read selection" button
// in the popover would read Myna's own window, never the user's document.
// That action stays a global hotkey; the popover only shows its hint.
import AppKit
import Foundation

@MainActor
public protocol MenuBarActionTarget: AnyObject {
    /// Speak a literal string through the normal synth+play pipeline.
    func speakText(_ text: String, mode: SynthesizeMode)
    /// Extract and read the front Chrome tab.
    func readChrome()
}

/// Reads the general pasteboard for the popover's clipboard actions.
///
/// SwiftUI calls `body` far more often than the clipboard changes, and this
/// popover re-renders on every 250ms poll tick, so the read is memoised on
/// `NSPasteboard.changeCount`: a copy anywhere on the system invalidates it,
/// a re-render does not.
@MainActor
public enum ClipboardProbe {
    private static var cachedChangeCount: Int = -1
    private static var cachedText: String?

    /// Current pasteboard string, trimmed — or nil when there is nothing
    /// readable (empty, whitespace-only, or a non-text flavour like an image).
    public static func text() -> String? {
        let board = NSPasteboard.general
        if board.changeCount != cachedChangeCount {
            cachedChangeCount = board.changeCount
            let raw = board.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cachedText = (raw?.isEmpty == false) ? raw : nil
        }
        return cachedText
    }

    /// One-line preview for the action's subtitle. Collapses every run of
    /// whitespace so a multi-paragraph copy can't blow up the row height.
    public static func preview(_ text: String, limit: Int = 38) -> String {
        let flat = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Rough reading time, so the user knows whether they just queued a
    /// sentence or a thesis. 180 wpm is a common TTS listening rate.
    public static func durationLabel(_ text: String) -> String {
        let words = max(1, text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count)
        let minutes = Double(words) / 180.0
        if minutes < 1 { return "~\(max(5, Int((minutes * 60).rounded())))s" }
        return "~\(Int(minutes.rounded()))m"
    }
}
