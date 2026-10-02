// FeedbackFormTests.swift — the form's state machine, the disclosure line,
// and the window's editing-shortcut routing. No windows are opened.
import AppKit
import XCTest

@testable import Myna

private struct StubSender: FeedbackSending {
    let result: Result<String?, FeedbackError>
    let sent = SendableBox<[FeedbackDraft]>([])

    func send(_ draft: FeedbackDraft, context: FeedbackContext) async throws -> String? {
        sent.mutate { $0.append(draft) }
        return try result.get()
    }
}

@MainActor
final class FeedbackFormTests: XCTestCase {
    private let context = FeedbackContext(
        appVersion: "0.5.2",
        build: "20",
        osVersion: "26.0 (25A354)",
        deviceModel: "Mac16,5"
    )

    // MARK: - model

    func test_send_is_disabled_until_three_non_space_characters() {
        let model = FeedbackFormModel(kind: .problem, context: context, sender: StubSender(result: .success("fb_1")))
        XCTAssertFalse(model.canSend)
        model.message = " a b "
        XCTAssertFalse(model.canSend)
        model.message = "abc"
        XCTAssertTrue(model.canSend)
    }

    func test_success_replaces_the_form() async {
        let sender = StubSender(result: .success("fb_1"))
        let model = FeedbackFormModel(kind: .idea, context: context, sender: sender)
        model.message = "Per-app voices, please."
        model.email = "a@b.co"
        model.send()
        XCTAssertEqual(model.phase, .sending)
        XCTAssertFalse(model.canSend, "Send is disabled while sending")
        await model.waitForSend()
        XCTAssertEqual(model.phase, .sent)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(sender.sent.value, [FeedbackDraft(kind: .idea, message: "Per-app voices, please.", email: "a@b.co")])
    }

    func test_failure_keeps_everything_typed_and_shows_the_error() async {
        let model = FeedbackFormModel(kind: .problem, context: context, sender: StubSender(result: .failure(.couldNotSend)))
        model.message = "It stopped reading."
        model.name = "Asha"
        model.email = "asha@example.com"
        model.send()
        await model.waitForSend()
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.errorText, "Couldn't send. Check your connection and try again.")
        XCTAssertEqual(model.message, "It stopped reading.")
        XCTAssertEqual(model.name, "Asha")
        XCTAssertEqual(model.email, "asha@example.com")
        XCTAssertTrue(model.canSend, "can try again")
    }

    func test_server_sentence_is_shown_verbatim() async {
        let sentence = "That's a lot of messages in a short time. Please try again in a few minutes."
        let model = FeedbackFormModel(kind: .problem, context: context, sender: StubSender(result: .failure(.rejected(sentence))))
        model.message = "Again."
        model.send()
        await model.waitForSend()
        XCTAssertEqual(model.errorText, sentence)
    }

    func test_reopening_switches_kind_only_while_nothing_is_typed() {
        let model = FeedbackFormModel(kind: .problem, context: context, sender: StubSender(result: .success(nil)))
        model.prepare(for: .idea)
        XCTAssertEqual(model.kind, .idea)
        model.message = "Half-written thought"
        model.prepare(for: .problem)
        XCTAssertEqual(model.kind, .idea)
        XCTAssertEqual(model.message, "Half-written thought")
    }

    func test_reopening_after_sending_starts_a_fresh_form() async {
        let model = FeedbackFormModel(kind: .problem, context: context, sender: StubSender(result: .success("fb_2")))
        model.message = "Sent already."
        model.name = "Asha"
        model.send()
        await model.waitForSend()
        model.prepare(for: .idea)
        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.kind, .idea)
        XCTAssertEqual(model.message, "")
        XCTAssertEqual(model.name, "")
    }

    // MARK: - copy

    func test_kind_titles_and_placeholders_match_the_spec() {
        XCTAssertEqual(FeedbackKind.allCases.map(\.title), ["Problem", "Idea", "Other feedback"])
        XCTAssertEqual(FeedbackKind.allCases.map(\.rawValue), ["problem", "idea", "feedback"])
        XCTAssertEqual(FeedbackKind.problem.placeholder, "What happened, and what did you expect to happen?")
        XCTAssertEqual(FeedbackKind.idea.placeholder, "What would make Myna better for you?")
        XCTAssertEqual(FeedbackKind.feedback.placeholder, "Anything you'd like to tell me.")
    }

    func test_disclosure_line_lists_exactly_what_is_sent() {
        XCTAssertEqual(context.summary, "Sent with your message: Myna 0.5.2 (20) · macOS 26.0 (25A354) · Mac16,5")
        let noModel = FeedbackContext(appVersion: "0.5.2", build: "20", osVersion: "26.0", deviceModel: nil)
        XCTAssertEqual(noModel.summary, "Sent with your message: Myna 0.5.2 (20) · macOS 26.0")
    }

    func test_os_version_formatting() {
        XCTAssertEqual(FeedbackContext.formatOSVersion(major: 26, minor: 0, patch: 0, build: "25A354"), "26.0 (25A354)")
        XCTAssertEqual(FeedbackContext.formatOSVersion(major: 27, minor: 0, patch: 1, build: "26A434"), "27.0.1 (26A434)")
        XCTAssertEqual(FeedbackContext.formatOSVersion(major: 13, minor: 6, patch: 0, build: nil), "13.6")
    }

    func test_current_context_reads_the_bundle_and_the_mac() {
        let current = FeedbackContext.current()
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(current.appVersion, info["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(current.build, info["CFBundleVersion"] as? String)
        XCTAssertNotNil(current.deviceModel)
        XCTAssertTrue(current.osVersion.hasPrefix("\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)."))
    }

    // MARK: - window key routing

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    func test_editing_shortcuts_route_to_the_focused_field() throws {
        XCTAssertEqual(FeedbackWindow.editAction(for: try key("v", .command)), #selector(NSText.paste(_:)))
        XCTAssertEqual(FeedbackWindow.editAction(for: try key("c", .command)), #selector(NSText.copy(_:)))
        XCTAssertEqual(FeedbackWindow.editAction(for: try key("x", .command)), #selector(NSText.cut(_:)))
        XCTAssertEqual(FeedbackWindow.editAction(for: try key("a", .command)), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(FeedbackWindow.editAction(for: try key("z", .command)), Selector(("undo:")))
        XCTAssertEqual(FeedbackWindow.editAction(for: try key("Z", [.command, .shift])), Selector(("redo:")))
        XCTAssertNil(FeedbackWindow.editAction(for: try key("v", [.command, .option])))
        XCTAssertNil(FeedbackWindow.editAction(for: try key("v", [])))
    }
}
