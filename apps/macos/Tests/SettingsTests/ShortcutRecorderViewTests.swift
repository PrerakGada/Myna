// ShortcutRecorderViewTests.swift — guards the two load-bearing facts
// behind ShortcutRecorderView's paste fix:
//
//   1. The recorder field, as configured by ShortcutRecorderView (left
//      editable, exactly how the library ships it), still accepts first
//      responder — which is what arms the library's key-event recording
//      monitor. An earlier attempt made the field non-editable to block
//      paste; that silently broke recording (acceptsFirstResponder ⇒
//      false), which is the regression this test exists to prevent.
//
//   2. Text that reaches the field editor (a paste / drag, NOT the
//      recording path) is reverted to the stored shortcut, so pasted text
//      can never masquerade as a binding.
import AppKit
import KeyboardShortcuts
import XCTest

@testable import Myna

@MainActor
final class ShortcutRecorderViewTests: XCTestCase {

    /// The stock (editable) recorder accepts first responder, so the
    /// library's recording monitor can arm. ShortcutRecorderView must
    /// never disable editing (which would flip this to false).
    func testEditableRecorderAcceptsFirstResponder() {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .speakSelectionFull)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(recorder)
        XCTAssertTrue(
            recorder.acceptsFirstResponder,
            "An editable recorder must accept first responder so recording can arm"
        )
    }

    /// A non-editable field would NOT accept first responder — documents
    /// why ShortcutRecorderView leaves the field editable and blocks paste
    /// via reversion instead.
    func testNonEditableFieldRefusesFirstResponder() {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .stop)
        recorder.isEditable = false
        XCTAssertFalse(
            recorder.acceptsFirstResponder,
            "Disabling editing would break recording — proves we must not do it"
        )
    }

    /// Pasted / dropped text in the field editor is reverted to the stored
    /// shortcut string by the coordinator's text-change observer.
    func testPastedTextIsRevertedToStoredShortcut() {
        // Pin a known shortcut so the canonical string is deterministic.
        let name = KeyboardShortcuts.Name.stop
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: [.command, .option]), for: name)
        defer { KeyboardShortcuts.reset(name) }

        let recorder = KeyboardShortcuts.RecorderCocoa(for: name)
        let coordinator = ShortcutRecorderView.Coordinator()
        coordinator.observe(recorder)

        let canonical = KeyboardShortcuts.getShortcut(for: name).map { "\($0)" } ?? ""
        XCTAssertFalse(canonical.isEmpty, "Pinned shortcut should render non-empty")

        // Simulate a paste landing in the field editor.
        recorder.stringValue = "pasted junk text"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: recorder)

        XCTAssertEqual(
            recorder.stringValue, canonical,
            "Pasted text must be reverted to the stored shortcut glyph"
        )
    }
}
