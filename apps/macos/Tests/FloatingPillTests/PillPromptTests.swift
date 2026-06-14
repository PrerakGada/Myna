// PillPromptTests.swift — pins the dedup logic that decides which Claude-output
// item the pill prompts with: newest-unhandled, gated by the CC-toasts setting.
import XCTest

@testable import Myna

@MainActor
final class PillPromptTests: XCTestCase {
    private func item(_ id: String) -> RegistryV2Item {
        RegistryV2Item(
            id: id, source: "claude-code", projectId: "proj",
            title: "Reply \(id)", announcedAtMs: 0, ttlS: 60)
    }

    func test_disabled_returns_nil() {
        XCTAssertNil(PillController.nextCCPrompt(
            items: [item("a")], handled: [], enabled: false))
    }

    func test_empty_returns_nil() {
        XCTAssertNil(PillController.nextCCPrompt(
            items: [], handled: [], enabled: true))
    }

    func test_returns_newest_unhandled() {
        // ccPending is newest-first, so the first element is the newest.
        let r = PillController.nextCCPrompt(
            items: [item("a"), item("b")], handled: [], enabled: true)
        XCTAssertEqual(r?.id, "a")
    }

    func test_skips_handled_to_next() {
        let r = PillController.nextCCPrompt(
            items: [item("a"), item("b")], handled: ["a"], enabled: true)
        XCTAssertEqual(r?.id, "b")
    }

    func test_all_handled_returns_nil() {
        let r = PillController.nextCCPrompt(
            items: [item("a"), item("b")], handled: ["a", "b"], enabled: true)
        XCTAssertNil(r)
    }
}
