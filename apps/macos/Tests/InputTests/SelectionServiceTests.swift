// SelectionServiceTests.swift — verifies clipboard save/restore and the
// "no selection → nil" path. Real CGEvent posting is stubbed so the
// test host doesn't need Accessibility.
import AppKit
import XCTest

@testable import Myna

final class SelectionServiceTests: XCTestCase {
    func test_capture_returns_pasteboard_string_after_cmd_c() async {
        let pasteboard = FakePasteboard()
        let poster = FakeKeyPoster(onPost: { pasteboard.simulateAppPlacingOnClipboard("hello") })
        let service = SelectionService(pasteboard: pasteboard, keyPoster: poster, copyWaitNanos: 1_000_000)
        let text = await service.captureSelectedText()
        XCTAssertEqual(text, "hello")
    }

    func test_capture_restores_prior_clipboard() async {
        let pasteboard = FakePasteboard()
        pasteboard.seed(with: "before")
        let poster = FakeKeyPoster(onPost: { pasteboard.simulateAppPlacingOnClipboard("selection") })
        let service = SelectionService(pasteboard: pasteboard, keyPoster: poster, copyWaitNanos: 1_000_000)
        _ = await service.captureSelectedText()
        XCTAssertEqual(pasteboard.pasteboardString, "before")
        XCTAssertEqual(pasteboard.restoreCallCount, 1)
    }

    func test_capture_returns_nil_when_no_selection() async {
        let pasteboard = FakePasteboard()
        let poster = FakeKeyPoster()  // no injection — pasteboard stays empty
        let service = SelectionService(pasteboard: pasteboard, keyPoster: poster, copyWaitNanos: 1_000_000)
        let text = await service.captureSelectedText()
        XCTAssertNil(text)
    }

    func test_capture_returns_nil_when_accessibility_denied() async {
        let pasteboard = FakePasteboard()
        pasteboard.seed(with: "before")
        let poster = FakeKeyPoster(succeed: false)
        let service = SelectionService(pasteboard: pasteboard, keyPoster: poster, copyWaitNanos: 1_000_000)
        let text = await service.captureSelectedText()
        XCTAssertNil(text)
        // Clipboard must still be exactly what it was.
        XCTAssertEqual(pasteboard.pasteboardString, "before")
    }
}

// MARK: - test doubles

/// Mimics NSPasteboard's snapshot/restore semantics. Tests inject a
/// "what the app would have placed on the clipboard during Cmd+C" string
/// via `simulateAppPlacingOnClipboard(_:)`.
private final class FakePasteboard: PasteboardProtocol, @unchecked Sendable {
    private var current: String?
    var restoreCallCount = 0

    func seed(with value: String) {
        current = value
    }

    /// Pretend the front app responded to Cmd+C by writing this string
    /// to the pasteboard. Test helper, not part of the protocol.
    func simulateAppPlacingOnClipboard(_ value: String) {
        current = value
    }

    var pasteboardString: String? {
        get { current }
        set { current = newValue }
    }

    func saveSnapshot() -> [NSPasteboardItem] {
        guard let current else { return [] }
        let item = NSPasteboardItem()
        item.setString(current, forType: .string)
        return [item]
    }

    func restore(_ items: [NSPasteboardItem]) {
        restoreCallCount += 1
        current = items.first?.string(forType: .string)
    }

    func clearContents() {
        current = nil
    }
}

private struct FakeKeyPoster: KeyPostingProtocol {
    let succeed: Bool
    let onPost: (@Sendable () -> Void)?

    init(succeed: Bool = true, onPost: (@Sendable () -> Void)? = nil) {
        self.succeed = succeed
        self.onPost = onPost
    }

    func postCmdC() -> Bool {
        onPost?()
        return succeed
    }
}
