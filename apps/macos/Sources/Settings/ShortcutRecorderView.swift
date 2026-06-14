// ShortcutRecorderView.swift — SwiftUI wrapper around the KeyboardShortcuts
// library's AppKit recorder (`KeyboardShortcuts.RecorderCocoa`).
//
// We use this instead of the library's stock SwiftUI `Recorder` so we can
// fix one behaviour the stock view doesn't expose: blocking pasted text in
// the recorder field.
//
// How recording vs. text entry actually works in the library:
//   • A *chord* is captured by a local key-event monitor the library
//     installs in `becomeFirstResponder()`. Plain typing is swallowed by
//     that monitor (it beeps on a bare key), so you cannot type junk in.
//   • But `RecorderCocoa` is an editable `NSSearchField`, and the `paste:`
//     action (right-click ▸ Paste, Edit ▸ Paste, or a text drag) is NOT a
//     key event — it bypasses the monitor and the field editor happily
//     inserts the text, which then sits there looking like a (bogus)
//     binding.
//
// We must NOT fix this by making the field non-editable: an NSSearchField
// only reports `acceptsFirstResponder == true` while editable, so a
// non-editable field never becomes first responder and recording silently
// stops working (verified in ShortcutRecorderViewTests). Instead we leave
// the field exactly as the library configures it and simply revert any text
// the field editor receives back to the real stored shortcut. Programmatic
// shortcut updates (the recording path) don't post the text-change
// notification, so this only ever catches paste/drag — recording is
// untouched.
//
// `RecorderCocoa` is `final`, so wrapping + observing is the only seam.
import AppKit
import KeyboardShortcuts
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: name)
        context.coordinator.observe(recorder)
        return recorder
    }

    func updateNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, context: Context) {
        if nsView.shortcutName != name {
            nsView.shortcutName = name
        }
    }

    static func dismantleNSView(_ nsView: KeyboardShortcuts.RecorderCocoa, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    /// Watches the recorder's field editor and snaps it back to the real
    /// stored shortcut whenever text arrives that wasn't put there by the
    /// recording path (i.e. a paste or drag). Uses a selector-based
    /// observer rather than a closure so it composes cleanly with Swift 6
    /// strict concurrency (no `@Sendable` capture of the AppKit view).
    @MainActor
    final class Coordinator: NSObject {
        private weak var recorder: KeyboardShortcuts.RecorderCocoa?

        func observe(_ recorder: KeyboardShortcuts.RecorderCocoa) {
            self.recorder = recorder
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fieldTextDidChange(_:)),
                name: NSControl.textDidChangeNotification,
                object: recorder
            )
        }

        @objc private func fieldTextDidChange(_ note: Notification) {
            guard let recorder else { return }
            // An empty field editor is a legitimate user clear (Delete key,
            // the cancel "X", or Cut) — let the library persist nil; reverting
            // here would fight that. Pasted / dropped text is always
            // non-empty, so only non-empty foreign text needs reverting to
            // the stored shortcut glyph. (The recording path sets stringValue
            // programmatically, which does NOT post this notification, so
            // recording is never affected — and this guard means correctness
            // no longer depends on observer registration order.)
            guard !recorder.stringValue.isEmpty else { return }
            let canonical = KeyboardShortcuts.getShortcut(for: recorder.shortcutName).map { "\($0)" } ?? ""
            if recorder.stringValue != canonical {
                recorder.stringValue = canonical
            }
        }

        func invalidate() {
            NotificationCenter.default.removeObserver(self)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
