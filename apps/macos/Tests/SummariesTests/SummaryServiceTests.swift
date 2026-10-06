// SummaryServiceTests.swift — what a summary read sends: Apple's summary as
// a full read, or `mode: "summary"` + `summary_style` for the daemon, or
// nothing and a notice. Plus prewarm, the Try button and the client calls.
import XCTest

@testable import Myna

@MainActor
final class SummaryServiceTests: XCTestCase {

    private func service(
        model: FakeOnDeviceModel, daemon: FakeSummaryDaemon? = FakeSummaryDaemon(),
        choice: SummaryBackendChoice = .automatic, style: SummaryStyle = .keyPoints
    ) -> SummaryService {
        SummaryService(model: model, daemon: daemon, preferences: { (choice, style) })
    }

    private func summaryRead(_ text: String = "A long article body.") -> SynthesizeRequest {
        SynthesizeRequest(text: text, voice: "af_heart", mode: .summary, sessionId: "s", bundleId: "com.example")
    }

    func test_a_full_read_passes_through_untouched() async {
        let model = FakeOnDeviceModel()
        let read = SynthesizeRequest(text: "Read me.", mode: .full)
        let step = await service(model: model).request(for: read)
        XCTAssertEqual(step, .send(read))
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func test_apple_path_sends_the_summary_as_a_full_read_without_a_style() async throws {
        let model = FakeOnDeviceModel(answer: { _ in "First, it works. Second, it is quick." })
        let daemon = FakeSummaryDaemon()
        let step = await service(model: model, daemon: daemon).request(for: summaryRead())
        guard case .send(let sent) = step else { return XCTFail("expected send, got \(step)") }
        XCTAssertEqual(sent.mode, .full)
        XCTAssertEqual(sent.text, "First, it works. Second, it is quick.")
        XCTAssertNil(sent.summaryStyle)
        XCTAssertEqual(sent.voice, "af_heart")
        XCTAssertEqual(sent.bundleId, "com.example")
        XCTAssertEqual(model.prompts, [SummaryPrompts.prompt(.keyPoints, text: "A long article body.")])
        let json = try SummariesTests.json(sent)
        XCTAssertNil(json["summary_style"])
        XCTAssertEqual(json["mode"] as? String, "full")
        XCTAssertTrue(daemon.summarizeCalls.isEmpty)
    }

    func test_fallback_path_keeps_summary_mode_and_adds_the_style() async throws {
        let model = FakeOnDeviceModel(status: .notEnabled)
        let step = await service(model: model, style: .actionItems).request(for: summaryRead())
        guard case .send(let sent) = step else { return XCTFail("expected send, got \(step)") }
        XCTAssertEqual(sent.mode, .summary)
        XCTAssertEqual(sent.text, "A long article body.")
        XCTAssertEqual(try SummariesTests.json(sent)["summary_style"] as? String, "action_items")
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func test_a_refusal_falls_back_to_the_daemon() async {
        let model = FakeOnDeviceModel(answer: { _ in throw OnDeviceFailure.refused })
        let step = await service(model: model).request(for: summaryRead())
        guard case .send(let sent) = step else { return XCTFail("expected send, got \(step)") }
        XCTAssertEqual(sent.mode, .summary)
        XCTAssertEqual(sent.summaryStyle, "key_points")
    }

    func test_neither_backend_halts_with_a_notice() async {
        let model = FakeOnDeviceModel(status: .notEnabled)
        let step = await service(model: model, daemon: FakeSummaryDaemon(state: "not_installed")).request(for: summaryRead())
        guard case .halt(let notice?) = step else { return XCTFail("expected a notice, got \(step)") }
        XCTAssertEqual(notice.title, "Summaries need Apple Intelligence or Ollama")
        XCTAssertTrue(notice.hint.contains("System Settings ▸ Apple Intelligence & Siri"))
    }

    func test_ollama_only_never_calls_apple() async {
        let model = FakeOnDeviceModel()
        let step = await service(model: model, choice: .ollama).request(for: summaryRead())
        guard case .send(let sent) = step else { return XCTFail("expected send") }
        XCTAssertEqual(sent.mode, .summary)
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func test_a_daemon_that_does_not_answer_the_probe_still_gets_the_read() async {
        let model = FakeOnDeviceModel(status: .downloading)
        let daemon = FakeSummaryDaemon()
        daemon.statusFails = true
        let summaries = service(model: model, daemon: daemon)
        let step = await summaries.request(for: summaryRead())
        guard case .send(let sent) = step else { return XCTFail("expected send") }
        XCTAssertEqual(sent.mode, .summary)
        XCTAssertEqual(summaries.ollamaStatus, .unknown)
    }

    func test_an_article_url_summary_goes_to_the_daemon() async {
        let model = FakeOnDeviceModel()
        let read = SynthesizeRequest(url: "https://example.com/a", mode: .summary)
        let step = await service(model: model).request(for: read)
        guard case .send(let sent) = step else { return XCTFail("expected send") }
        XCTAssertEqual(sent.url, "https://example.com/a")
        XCTAssertEqual(sent.summaryStyle, "key_points")
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func test_halt_after_a_daemon_summary_failure_carries_its_notice() {
        let summaries = service(model: FakeOnDeviceModel())
        let error = DaemonError.http(503, #"{"ok":false,"reason":"ollama_not_running","detail":"refused"}"#)
        guard case .halt(let notice?) = summaries.halt(after: error, mode: .summary) else {
            return XCTFail("expected a notice")
        }
        XCTAssertEqual(notice.title, "Ollama isn't running")
        XCTAssertEqual(summaries.halt(after: error, mode: .full), .halt(nil))
        XCTAssertEqual(summaries.halt(after: DaemonError.engineDown, mode: .summary), .halt(nil))
    }

    // MARK: - prewarm

    func test_prewarm_loads_apple_with_the_styles_prompt_prefix() {
        let model = FakeOnDeviceModel()
        service(model: model, style: .plainEnglish).prewarm()
        XCTAssertEqual(model.prewarms, [SummaryPrompts.promptPrefix(.plainEnglish)])
    }

    func test_prewarm_does_nothing_for_ollama_or_an_unready_model() {
        let model = FakeOnDeviceModel()
        service(model: model, choice: .ollama).prewarm()
        let unready = FakeOnDeviceModel(status: .notEnabled)
        service(model: unready).prewarm()
        XCTAssertTrue(model.prewarms.isEmpty)
        XCTAssertTrue(unready.prewarms.isEmpty)
    }

    // MARK: - Try

    func test_try_with_apple_returns_text_and_timing_and_speaks_nothing() async {
        let model = FakeOnDeviceModel(answer: { _ in "The office moves on Friday the 14th." })
        let trial = await service(model: model).trySample(style: .tldr)
        XCTAssertEqual(trial.backend, .apple)
        XCTAssertEqual(trial.text, "The office moves on Friday the 14th.")
        XCTAssertNotNil(trial.timing)
        XCTAssertEqual(model.prompts, [SummaryPrompts.prompt(.tldr, text: SummarySample.text)])
    }

    func test_try_with_ollama_asks_the_daemon_in_the_chosen_style() async {
        let daemon = FakeSummaryDaemon()
        let trial = await service(model: FakeOnDeviceModel(), daemon: daemon, choice: .ollama)
            .trySample(style: .plainEnglish)
        XCTAssertEqual(trial.backend, .ollama)
        XCTAssertEqual(trial.text, "Ollama's summary.")
        XCTAssertEqual(daemon.summarizeCalls.first?.style, "plain_english")
    }

    func test_try_shows_the_notice_a_read_would() async {
        let trial = await service(
            model: FakeOnDeviceModel(status: .notSupported), daemon: FakeSummaryDaemon(state: "model_missing")
        ).trySample(style: .tldr)
        XCTAssertNil(trial.text)
        XCTAssertEqual(trial.notice?.title, "Summaries need Apple Intelligence or Ollama")
    }

    func test_refresh_status_reads_both_backends() async {
        let model = FakeOnDeviceModel(status: .downloading)
        let summaries = service(model: model, daemon: FakeSummaryDaemon(state: "model_missing"))
        await summaries.refreshStatus()
        XCTAssertEqual(summaries.appleStatus, .downloading)
        XCTAssertEqual(summaries.ollamaStatus, .modelMissing(model: "qwen3.5:4b"))
    }

    // MARK: - DaemonClient calls

    func test_client_sends_the_style_and_decodes_the_status() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let sent = SendableBox<Data?>(nil)
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/summarize")
            sent.value = req.httpBody ?? req.httpBodyStream.map(Self.read)
            // swiftlint:disable:next force_unwrapping
            return (.make(url: req.url!, status: 200), Data(#"{"ok":true,"summary":"S"}"#.utf8))
        }
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/summarize/status")
            let body = #"{"ok":true,"ollama":{"state":"ready","model":"qwen3.5:4b","url":"http://127.0.0.1:11434"},"#
                + #""styles":["tldr","key_points","action_items","plain_english"],"default_style":"tldr"}"#
            // swiftlint:disable:next force_unwrapping
            return (.make(url: req.url!, status: 200), Data(body.utf8))
        }
        // swiftlint:disable:next force_unwrapping
        let client = DaemonClient(baseURL: URL(string: "http://127.0.0.1:8766")!, session: MockURLProtocol.session())
        let response = try await client.summarize(text: "long text", style: "key_points")
        XCTAssertEqual(response.summary, "S")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.value ?? Data()) as? [String: Any])
        XCTAssertEqual(json["summary_style"] as? String, "key_points")
        let status = try await client.summaryStatus()
        XCTAssertEqual(status.ollama.state, "ready")
        XCTAssertEqual(status.defaultStyle, "tldr")
    }

    nonisolated private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
