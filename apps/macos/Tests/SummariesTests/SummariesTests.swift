// SummariesTests.swift — the pure parts of summaries: which backend a
// summary uses, the notices, the style prompts (and that they match the
// daemon's Python word for word), splitting long text, and the request
// fields.
import XCTest

@testable import Myna

final class SummariesTests: XCTestCase {

    // MARK: - backend selection

    func test_automatic_prefers_apple_when_ready() {
        XCTAssertEqual(
            SummaryPlanner.route(choice: .automatic, apple: .ready, ollama: .ready(model: "m")), .apple)
        XCTAssertEqual(
            SummaryPlanner.route(choice: .automatic, apple: .ready, ollama: .notInstalled(model: "m")), .apple)
    }

    func test_automatic_uses_ollama_when_apple_is_not_ready() {
        for apple: AppleModelStatus in [.notEnabled, .downloading, .notSupported, .needsNewerMacOS] {
            XCTAssertEqual(
                SummaryPlanner.route(choice: .automatic, apple: apple, ollama: .ready(model: "m")), .ollama)
        }
    }

    func test_an_unknown_ollama_status_still_lets_the_daemon_try() {
        XCTAssertEqual(SummaryPlanner.route(choice: .automatic, apple: .notEnabled, ollama: .unknown), .ollama)
        XCTAssertEqual(SummaryPlanner.route(choice: .ollama, apple: .ready, ollama: .checking), .ollama)
    }

    func test_neither_names_both_fixes() throws {
        let route = SummaryPlanner.route(
            choice: .automatic, apple: .notEnabled, ollama: .notInstalled(model: "qwen3.5:4b"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice, got \(route)") }
        XCTAssertEqual(notice.title, "Summaries need Apple Intelligence or Ollama")
        XCTAssertTrue(notice.hint.contains("System Settings ▸ Apple Intelligence & Siri"), notice.hint)
        XCTAssertTrue(notice.hint.contains("ollama pull qwen3.5:4b"), notice.hint)
    }

    func test_neither_on_a_mac_without_apple_intelligence_points_at_ollama_only() {
        let route = SummaryPlanner.route(
            choice: .automatic, apple: .notSupported, ollama: .modelMissing(model: "qwen3.5:4b"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice") }
        XCTAssertTrue(notice.hint.hasPrefix("This Mac can't use Apple Intelligence"), notice.hint)
        XCTAssertTrue(notice.hint.contains("ollama pull qwen3.5:4b"))
    }

    func test_apple_only_never_falls_back() {
        let route = SummaryPlanner.route(choice: .apple, apple: .downloading, ollama: .ready(model: "m"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.title, "Apple Intelligence is still downloading")
        XCTAssertTrue(notice.hint.contains("Automatic"))
    }

    func test_ollama_only_skips_apple_even_when_ready() {
        XCTAssertEqual(SummaryPlanner.route(choice: .ollama, apple: .ready, ollama: .ready(model: "m")), .ollama)
        let route = SummaryPlanner.route(choice: .ollama, apple: .ready, ollama: .notRunning(model: "m"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.title, "Ollama isn't running")
    }

    func test_a_refusal_falls_back_to_ollama_on_automatic() {
        XCTAssertEqual(
            SummaryPlanner.routeAfterAppleFailure(.refused, choice: .automatic, ollama: .ready(model: "m")),
            .ollama)
        XCTAssertEqual(
            SummaryPlanner.routeAfterAppleFailure(.failed("boom"), choice: .automatic, ollama: .unknown), .ollama)
        XCTAssertEqual(
            SummaryPlanner.routeAfterAppleFailure(.unsupportedLanguage, choice: .automatic, ollama: .ready(model: "m")),
            .ollama)
    }

    func test_a_refusal_with_no_ollama_says_what_happened_and_how_to_fix_it() {
        let route = SummaryPlanner.routeAfterAppleFailure(
            .refused, choice: .automatic, ollama: .modelMissing(model: "qwen3.5:4b"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.title, "Apple Intelligence wouldn't summarize this")
        XCTAssertTrue(notice.hint.contains("ollama pull qwen3.5:4b"), notice.hint)
    }

    func test_a_refusal_on_apple_only_suggests_automatic() {
        let route = SummaryPlanner.routeAfterAppleFailure(.refused, choice: .apple, ollama: .ready(model: "m"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice") }
        XCTAssertTrue(notice.hint.contains("Set Summaries to Automatic"), notice.hint)
    }

    func test_too_long_does_not_hand_the_text_to_a_slower_model() {
        let route = SummaryPlanner.routeAfterAppleFailure(.timedOut, choice: .automatic, ollama: .ready(model: "m"))
        guard case .unavailable(let notice) = route else { return XCTFail("expected a notice") }
        XCTAssertEqual(notice.title, "This is too long to summarize")
    }

    func test_apple_becoming_unavailable_mid_read_is_routed_like_a_fresh_read() {
        XCTAssertEqual(
            SummaryPlanner.routeAfterAppleFailure(
                .unavailable(.downloading), choice: .automatic, ollama: .ready(model: "m")),
            .ollama)
    }

    // MARK: - daemon failures

    func test_a_daemon_503_with_a_reason_becomes_a_notice() {
        let body = #"{"ok": false, "reason": "summary_model_missing", "detail": "x"}"#
        let notice = SummaryPlanner.notice(forDaemonError: DaemonError.http(503, body), model: "qwen3.5:4b")
        XCTAssertEqual(notice?.title, "The summary model isn't downloaded")
        XCTAssertEqual(notice?.hint.contains("ollama pull qwen3.5:4b"), true)
        for reason in ["ollama_not_running", "ollama_not_installed", "summary_timeout", "summary_failed"] {
            let error = DaemonError.http(503, #"{"ok":false,"reason":"\#(reason)"}"#)
            XCTAssertNotNil(SummaryPlanner.notice(forDaemonError: error, model: "m"), reason)
        }
    }

    func test_other_errors_are_not_summary_notices() {
        XCTAssertNil(SummaryPlanner.notice(forDaemonError: DaemonError.engineDown, model: "m"))
        XCTAssertNil(SummaryPlanner.notice(forDaemonError: DaemonError.http(500, "oops"), model: "m"))
        XCTAssertNil(SummaryPlanner.notice(forDaemonError: DaemonError.http(503, "not json"), model: "m"))
    }

    func test_ollama_status_maps_the_daemon_states() {
        XCTAssertEqual(OllamaSummaryStatus(state: "ready", model: "m"), .ready(model: "m"))
        XCTAssertEqual(OllamaSummaryStatus(state: "model_missing", model: "m"), .modelMissing(model: "m"))
        XCTAssertEqual(OllamaSummaryStatus(state: "not_running", model: "m"), .notRunning(model: "m"))
        XCTAssertEqual(OllamaSummaryStatus(state: "not_installed", model: "m"), .notInstalled(model: "m"))
        XCTAssertEqual(OllamaSummaryStatus(state: "new_state", model: "m"), .unknown)
        XCTAssertEqual(OllamaSummaryStatus.ready(model: "qwen3.5:4b").statusLine, "Ollama: found, model qwen3.5:4b")
        XCTAssertEqual(OllamaSummaryStatus.notInstalled(model: "m").statusLine, "Ollama: not installed")
        XCTAssertEqual(AppleModelStatus.downloading.statusLine, "Apple Intelligence: downloading")
    }

    // MARK: - prompts

    func test_every_prompt_is_written_for_listening() {
        let rules = SummaryPrompts.instructions.lowercased()
        XCTAssertTrue(rules.contains("no markdown"))
        XCTAssertTrue(rules.contains("bullet points"))
        XCTAssertTrue(rules.contains("here is a summary"))
        XCTAssertTrue(rules.contains("listening"))
    }

    func test_each_style_builds_its_own_prompt_around_the_text() {
        let prompts = SummaryStyle.allCases.map { SummaryPrompts.prompt($0, text: "BODY") }
        XCTAssertEqual(Set(prompts).count, SummaryStyle.allCases.count)
        for style in SummaryStyle.allCases {
            let prompt = SummaryPrompts.prompt(style, text: "BODY")
            XCTAssertTrue(prompt.hasPrefix(SummaryPrompts.stylePrompt(style)))
            XCTAssertTrue(prompt.hasSuffix("TEXT:\nBODY"))
            XCTAssertTrue(prompt.hasPrefix(SummaryPrompts.promptPrefix(style)))
        }
        XCTAssertTrue(SummaryPrompts.stylePrompt(.keyPoints).contains("First, Second, Third"))
    }

    func test_map_and_reduce_prompts() {
        let part = SummaryPrompts.partPrompt("CHUNK", index: 2, count: 5)
        XCTAssertTrue(part.hasPrefix("This is part 2 of 5 of a longer text."))
        XCTAssertTrue(part.hasSuffix("TEXT:\nCHUNK"))
        let reduce = SummaryPrompts.reducePrompt(["one", "two"], style: .actionItems)
        XCTAssertTrue(reduce.hasPrefix(SummaryPrompts.stylePrompt(.actionItems)))
        XCTAssertTrue(reduce.hasSuffix("TEXT:\none\n\ntwo"))
    }

    /// The daemon's copy must say exactly the same thing (summarize.py).
    func test_prompts_match_the_daemon_word_for_word() throws {
        let python = try String(contentsOf: Self.summarizePy, encoding: .utf8)
        XCTAssertEqual(try Self.pythonString(python, after: "INSTRUCTIONS = ("), SummaryPrompts.instructions)
        for style in SummaryStyle.allCases {
            XCTAssertEqual(
                try Self.pythonString(python, after: "\"\(style.rawValue)\": ("),
                SummaryPrompts.stylePrompt(style), style.rawValue)
        }
        let part = try Self.pythonString(python, after: "_PART_PROMPT = (")
            .replacingOccurrences(of: "{index}", with: "3").replacingOccurrences(of: "{count}", with: "4")
        XCTAssertEqual(part + "\n\nTEXT:\nX", SummaryPrompts.partPrompt("X", index: 3, count: 4))
        let preface = try Self.pythonString(python, after: "_PARTS_PREFACE = (")
        XCTAssertEqual(
            SummaryPrompts.stylePrompt(.tldr) + "\n\n" + preface + "\n\nTEXT:\nA\n\nB",
            SummaryPrompts.reducePrompt(["A", "B"], style: .tldr))
    }

    func test_tidy_drops_what_the_prompt_forbids() {
        // Same cases as daemon/tests/test_summarize.py test_tidy_drops_what_the_prompt_forbids.
        let cases: [(String, String)] = [
            ("Here is a summary of the text:\nThe point.", "The point."),
            ("Sure, here's a summary: The point.", "The point."),
            ("- First, one.\n- Second, two.", "First, one.\nSecond, two."),
            ("1. First, one.\n2) Second, two.", "First, one.\nSecond, two."),
            ("## Summary\nThe **main** point.", "Summary\nThe main point."),
            ("Here the council voted: yes.", "Here the council voted: yes."),
            ("The year 2024 was long. It ended.", "The year 2024 was long. It ended."),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(SummaryPrompts.tidy(raw), expected, raw)
        }
    }

    // MARK: - splitting

    func test_short_text_is_one_part() {
        XCTAssertEqual(SummaryChunker.split("  Short text.  ", maxChars: 100), ["Short text."])
        XCTAssertEqual(SummaryChunker.split("   ", maxChars: 100), [])
    }

    func test_long_text_splits_under_the_limit_and_loses_nothing() {
        let text = (0..<40).map { "Paragraph \($0). " + String(repeating: "word ", count: 50) }
            .joined(separator: "\n\n")
        let parts = SummaryChunker.split(text, maxChars: 1_000)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1_000 })
        XCTAssertEqual(Self.words(parts.joined(separator: " ")), Self.words(text))
    }

    func test_a_giant_sentence_breaks_at_spaces() {
        let parts = SummaryChunker.split(String(repeating: "word ", count: 1_000), maxChars: 300)
        XCTAssertGreaterThan(parts.count, 10)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 300 })
    }

    func test_sentences_are_kept_whole_when_a_paragraph_is_too_long() {
        let paragraph = (0..<30).map { "Sentence number \($0) ends here." }.joined(separator: " ")
        for part in SummaryChunker.split(paragraph, maxChars: 200) {
            XCTAssertTrue(part.hasPrefix("Sentence number"), part)
            XCTAssertTrue(part.hasSuffix("ends here."), part)
        }
    }

    func test_halves_are_roughly_half() {
        let text = (0..<80).map { "Sentence \($0) is here." }.joined(separator: " ")
        let halves = SummaryChunker.halves(text)
        XCTAssertEqual(halves.count, 2)
        XCTAssertTrue(halves.allSatisfy { $0.count <= text.count * 3 / 5 })
        XCTAssertEqual(Self.words(halves.joined(separator: " ")), Self.words(text))
    }

    func test_part_size_follows_the_context_window() {
        let small = SummaryChunker.partChars(contextTokens: 4_096, style: .tldr)
        let large = SummaryChunker.partChars(contextTokens: 8_192, style: .tldr)
        XCTAssertEqual(small, 9_588)  // (4096 − 400 − 500) × 3
        XCTAssertEqual(large, 16_000)  // capped, like the daemon's PART_CHARS
        XCTAssertLessThan(SummaryChunker.partChars(contextTokens: 4_096, style: .plainEnglish), small)
        XCTAssertEqual(SummaryChunker.partChars(contextTokens: 8_192, style: .plainEnglish), 9_000)
        XCTAssertEqual(SummaryChunker.partChars(contextTokens: 100, style: .tldr), SummaryChunker.minPartChars)
    }

    // MARK: - request fields

    func test_summary_style_is_sent_only_when_set() throws {
        var request = SynthesizeRequest(text: "t", mode: .summary)
        XCTAssertNil(try Self.json(request)["summary_style"])
        request.summaryStyle = "key_points"
        XCTAssertEqual(try Self.json(request)["summary_style"] as? String, "key_points")
        let summarize = try Self.json(SummarizeRequest(text: "t", summaryStyle: "plain_english"))
        XCTAssertEqual(summarize["summary_style"] as? String, "plain_english")
        XCTAssertNil(try Self.json(SummarizeRequest(text: "t"))["summary_style"])
    }

    func test_preferences_default_and_ignore_unknown_values() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SummariesTests.\(UUID().uuidString)"))
        XCTAssertEqual(SummaryPreferences.backend(defaults), .automatic)
        XCTAssertEqual(SummaryPreferences.style(defaults), .tldr)
        defaults.set("ollama", forKey: SummaryPreferences.backendKey)
        defaults.set("key_points", forKey: SummaryPreferences.styleKey)
        XCTAssertEqual(SummaryPreferences.backend(defaults), .ollama)
        XCTAssertEqual(SummaryPreferences.style(defaults), .keyPoints)
        defaults.set("haiku", forKey: SummaryPreferences.styleKey)
        XCTAssertEqual(SummaryPreferences.style(defaults), .tldr)
    }

    // MARK: - helpers

    static var summarizePy: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SummariesTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo
            .appendingPathComponent("daemon/myna/summarize.py")
    }

    /// The Python string a parenthesised run of adjacent literals makes,
    /// starting after `marker`: `("a " "b")` is "a b".
    static func pythonString(_ source: String, after marker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker), "missing \(marker)").upperBound
        var out = ""
        var inString = false
        var escaped = false
        for char in source[start...] {
            if inString {
                if escaped {
                    out.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                } else {
                    out.append(char)
                }
            } else if char == "\"" {
                inString = true
            } else if char == ")" {
                return out
            }
        }
        throw XCTSkip("unterminated literal after \(marker)")
    }

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }

    static func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
