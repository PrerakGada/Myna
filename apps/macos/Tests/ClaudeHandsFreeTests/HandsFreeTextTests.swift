// HandsFreeTextTests.swift — the spoken alert lines, the reply prefix, and
// how a reply is cut into passages.
import XCTest

@testable import Myna

final class HandsFreeTextTests: XCTestCase {
    private func attention(_ type: String?, message: String, project: String = "myna") -> RegistryV2Item {
        RegistryV2Item(
            id: "a_1", source: "claude-code", projectId: project, title: message, text: message,
            announcedAtMs: 0, ttlS: 600, kind: "attention", notificationType: type)
    }

    // MARK: phrasing

    func test_permission_prompt_names_project_and_action() {
        XCTAssertEqual(
            HandsFreePhrasing.alertLine(for: attention("permission_prompt",
                                                       message: "Claude needs your permission to use Bash")),
            "myna needs you, permission to run a command")
        XCTAssertEqual(
            HandsFreePhrasing.alertLine(for: attention("permission_prompt", message: "Allow Edit tool use?",
                                                       project: "Gala-ERP")),
            "Gala ERP needs you, permission to edit files")
    }

    func test_permission_for_mcp_and_unknown_tools() {
        XCTAssertEqual(HandsFreePhrasing.permissionAction(
            message: "Claude needs your permission to use mcp__github__create_issue"), "use github")
        XCTAssertEqual(HandsFreePhrasing.permissionAction(
            message: "Claude needs your permission to use Frobnicate"), "use Frobnicate")
        XCTAssertNil(HandsFreePhrasing.permissionAction(message: "Something odd"))
        XCTAssertEqual(
            HandsFreePhrasing.alertLine(for: attention("permission_prompt", message: "Something odd")),
            "myna needs your permission")
    }

    func test_other_needs_you_types() {
        XCTAssertEqual(HandsFreePhrasing.alertLine(for: attention("idle_prompt", message: "x")),
                       "myna is waiting for you")
        XCTAssertEqual(HandsFreePhrasing.alertLine(for: attention("elicitation_dialog", message: "x")),
                       "myna has a question for you")
        XCTAssertEqual(HandsFreePhrasing.alertLine(for: attention("agent_needs_input", message: "x")),
                       "myna needs your input")
        XCTAssertEqual(HandsFreePhrasing.alertLine(for: attention(nil, message: "x")), "myna needs you")
    }

    func test_alert_lines_stay_short() {
        let item = attention("permission_prompt", message: "Claude needs your permission to use WebFetch",
                             project: "engaze_monorepo")
        let line = HandsFreePhrasing.alertLine(for: item) ?? ""
        let projectWords = HandsFreePhrasing.spokenProject("engaze_monorepo").split(separator: " ").count
        XCTAssertLessThanOrEqual(line.split(separator: " ").count - projectWords, 8, line)
    }

    func test_replies_have_no_alert_line() {
        let reply = RegistryV2Item(id: "u", source: "claude-code", projectId: "myna", title: "t",
                                   announcedAtMs: 0, ttlS: 600)
        XCTAssertNil(HandsFreePhrasing.alertLine(for: reply))
    }

    func test_spoken_project_and_prefix() {
        XCTAssertEqual(HandsFreePhrasing.spokenProject("Gala-ERP"), "Gala ERP")
        XCTAssertEqual(HandsFreePhrasing.spokenProject("my_app.v2"), "my app v2")
        XCTAssertEqual(HandsFreePhrasing.spokenProject("--"), "Claude")
        XCTAssertEqual(HandsFreePhrasing.replyPrefix(projectId: "myna"), "From myna.")
    }

    // MARK: segmenting

    func test_short_reply_is_one_passage() {
        XCTAssertEqual(ReplySegmenter.passages(of: "Done. Tests pass."), ["Done. Tests pass."])
        XCTAssertEqual(ReplySegmenter.passages(of: "  \n\n "), [])
    }

    func test_small_paragraphs_are_packed_together() {
        let text = "First para.\n\nSecond para.\n\n\n- item one\n- item two"
        XCTAssertEqual(ReplySegmenter.passages(of: text),
                       ["First para.\n\nSecond para.\n\n- item one\n- item two"])
    }

    func test_paragraphs_split_at_the_limit() {
        let para = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces) + "."
        let text = [para, para, para].joined(separator: "\n\n")
        let passages = ReplySegmenter.passages(of: text, maxChars: para.count * 2 + 2)
        XCTAssertEqual(passages, [para + "\n\n" + para, para])
    }

    func test_long_paragraph_splits_between_sentences_and_keeps_every_word() {
        let sentence = "This sentence is about sixty characters long, give or take."
        let paragraph = Array(repeating: sentence, count: 25).joined(separator: " ")
        let passages = ReplySegmenter.passages(of: paragraph, maxChars: 200)
        XCTAssertGreaterThan(passages.count, 1)
        for passage in passages {
            XCTAssertLessThanOrEqual(passage.count, 200)
            XCTAssertTrue(passage.hasSuffix("take."), "split between sentences: \(passage)")
        }
        XCTAssertEqual(words(passages.joined(separator: " ")), words(paragraph))
    }

    func test_run_on_sentence_is_hard_wrapped_at_words() {
        let runOn = Array(repeating: "token", count: 100).joined(separator: " ")
        let passages = ReplySegmenter.passages(of: runOn, maxChars: 100)
        XCTAssertTrue(passages.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(words(passages.joined(separator: " ")), words(runOn))
    }

    private func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}
