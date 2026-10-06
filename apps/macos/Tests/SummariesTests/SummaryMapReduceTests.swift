// SummaryMapReduceTests.swift — long text on a small context window, with a
// scripted model: one call when it fits, parts then a reduce when it
// doesn't, rewrites in order for Plain English, splitting again when the
// model says a call overflowed, and the time budget.
import XCTest

@testable import Myna

final class SummaryMapReduceTests: XCTestCase {

    /// ~34,000 characters: four parts at a 4,096-token window.
    private static let longText = (0..<30)
        .map { "Paragraph \($0) says something. " + String(repeating: "More about the topic here. ", count: 40) }
        .joined(separator: "\n\n")

    func test_text_that_fits_takes_one_call() async throws {
        let model = FakeOnDeviceModel(answer: { _ in "Here is a summary:\nThe main point." })
        let output = try await MapReduceSummarizer(model: model).summarize("A short article.", style: .tldr)
        XCTAssertEqual(model.prompts, [SummaryPrompts.prompt(.tldr, text: "A short article.")])
        XCTAssertEqual(output.text, "The main point.")  // tidied
        XCTAssertEqual(output.timing.calls, 1)
        XCTAssertNotNil(output.timing.firstTokenSeconds)
    }

    func test_long_text_is_digested_in_parts_then_reduced_in_the_style() async throws {
        let model = FakeOnDeviceModel(contextTokens: 4_096, answer: { prompt in
            prompt.hasPrefix("This is part") ? "Digest." : "First, one point. Second, another."
        })
        let output = try await MapReduceSummarizer(model: model).summarize(Self.longText, style: .keyPoints)
        let parts = SummaryChunker.split(
            Self.longText, maxChars: SummaryChunker.partChars(contextTokens: 4_096, style: .keyPoints))
        XCTAssertGreaterThanOrEqual(parts.count, 3)
        XCTAssertEqual(model.prompts.count, parts.count + 1)
        for (offset, prompt) in model.prompts.dropLast().enumerated() {
            XCTAssertTrue(prompt.hasPrefix("This is part \(offset + 1) of \(parts.count)"), prompt.prefix(40).description)
        }
        let reduce = try XCTUnwrap(model.prompts.last)
        XCTAssertEqual(reduce, SummaryPrompts.reducePrompt(Array(repeating: "Digest.", count: parts.count), style: .keyPoints))
        XCTAssertEqual(output.text, "First, one point. Second, another.")
        XCTAssertEqual(output.timing.calls, parts.count + 1)
    }

    func test_long_plain_english_is_rewritten_part_by_part_without_a_reduce() async throws {
        let counter = Counter()
        let model = FakeOnDeviceModel(contextTokens: 4_096, answer: { _ in "Rewrite \(counter.next())." })
        let output = try await MapReduceSummarizer(model: model).summarize(Self.longText, style: .plainEnglish)
        let parts = SummaryChunker.split(
            Self.longText, maxChars: SummaryChunker.partChars(contextTokens: 4_096, style: .plainEnglish))
        XCTAssertEqual(model.prompts.count, parts.count)
        XCTAssertTrue(model.prompts.allSatisfy { $0.hasPrefix(SummaryPrompts.stylePrompt(.plainEnglish)) })
        XCTAssertEqual(output.text, (1...parts.count).map { "Rewrite \($0)." }.joined(separator: "\n\n"))
    }

    func test_a_context_overflow_splits_the_text_and_tries_again() async throws {
        // The model can only take prompts under 1,500 characters.
        let model = FakeOnDeviceModel(contextTokens: 8_192, answer: { prompt in
            if prompt.count > 1_500 { throw OnDeviceFailure.contextExceeded }
            return prompt.hasPrefix("This is part") ? "Digest." : "Summary."
        })
        let text = (0..<12).map { "Sentence \($0) carries a fact worth keeping for later." }
            .joined(separator: " ") + " " + String(repeating: "Filler words go here. ", count: 60)
        let output = try await MapReduceSummarizer(model: model).summarize(text, style: .tldr)
        XCTAssertEqual(output.text, "Summary.")
        XCTAssertTrue(model.prompts.contains { $0.hasPrefix("This is part") }, "expected digests after the overflow")
        XCTAssertTrue(model.prompts.last?.contains("digests of consecutive parts") ?? false)
    }

    func test_an_overflow_on_a_tiny_text_is_reported_not_retried_forever() async {
        let model = FakeOnDeviceModel(answer: { _ in throw OnDeviceFailure.contextExceeded })
        do {
            _ = try await MapReduceSummarizer(model: model).summarize("Tiny.", style: .tldr)
            XCTFail("expected contextExceeded")
        } catch {
            XCTAssertEqual(error as? OnDeviceFailure, .contextExceeded)
            XCTAssertEqual(model.prompts.count, 1)
        }
    }

    func test_a_refusal_is_passed_up() async {
        let model = FakeOnDeviceModel(answer: { _ in throw OnDeviceFailure.refused })
        do {
            _ = try await MapReduceSummarizer(model: model).summarize("Text.", style: .tldr)
            XCTFail("expected refused")
        } catch {
            XCTAssertEqual(error as? OnDeviceFailure, .refused)
        }
    }

    func test_the_budget_stops_a_long_job_between_calls() async {
        let clock = ManualClock()
        // Each call takes 50 "seconds"; the budget is 120.
        let model = FakeOnDeviceModel(contextTokens: 4_096, answer: { _ in
            clock.advance(50)
            return "Digest."
        })
        let summarizer = MapReduceSummarizer(model: model, budget: 120, now: { clock.now })
        do {
            _ = try await summarizer.summarize(Self.longText, style: .tldr)
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? OnDeviceFailure, .timedOut)
            XCTAssertEqual(model.prompts.count, 3)  // 0, 50, 100 started; 150 is past the deadline
        }
    }

    func test_a_single_call_that_hangs_is_cut_off() async {
        let model = SlowModel()
        let summarizer = MapReduceSummarizer(model: model, budget: 0.2)
        let started = Date()
        do {
            _ = try await summarizer.summarize("Text.", style: .tldr)
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? OnDeviceFailure, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Answers after ten seconds unless cancelled.
private struct SlowModel: OnDeviceLanguageModel {
    var status: AppleModelStatus { .ready }
    var contextTokens: Int { 4_096 }
    func prewarm(instructions: String, promptPrefix: String) {}
    func respond(instructions: String, prompt: String) async throws -> OnDeviceAnswer {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return OnDeviceAnswer(text: "late")
    }
}
