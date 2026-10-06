// PlaygroundModelTests.swift — the render path end to end against a
// stubbed daemon: voice defaults, what a render request carries, takes
// made from the daemon's headers, comparisons, cancel, errors, drops.
import XCTest

@testable import Myna

@MainActor
final class PlaygroundModelTests: XCTestCase {

    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8766")!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        // No super.setUp(): sending the XCTestCase across actors fails CI's Swift 6 (see PillSettingsTests).
        MockURLProtocol.reset()
        directory = PlaygroundFixtures.tempDirectory("model")
        suiteName = "playground-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(preferredVoice: String? = "af_bella") -> PlaygroundModel {
        let model = PlaygroundModel(
            client: DaemonClient(baseURL: baseURL, session: MockURLProtocol.session()),
            render: RenderClient(baseURL: baseURL, session: MockURLProtocol.session()),
            store: PlaygroundTakeStore(directory: directory),
            defaults: defaults,
            preferredVoice: { preferredVoice }
        )
        model.playWhenReady = false
        return model
    }

    /// Queues /v2/engines, /v2/voices and /v2/formats, in the order refresh() asks.
    private func stubRefresh(nativeSpeed: Bool = true, voices: Data? = nil, formats: [[String: Any]]? = nil) {
        let engines: [String: Any] = [
            "active": "kokoro",
            "switching_to": NSNull(),
            "engines": [PlaygroundFixtures.engineJSON(id: "kokoro", name: "Kokoro", nativeSpeed: nativeSpeed)],
        ]
        let enginesData = PlaygroundFixtures.json(engines)
        MockURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/v2/engines")
            return PlaygroundFixtures.respond(request, status: 200, body: enginesData)
        }
        let voicesData = voices ?? PlaygroundFixtures.voicesData
        MockURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/v2/voices")
            return PlaygroundFixtures.respond(request, status: 200, body: voicesData)
        }
        let formatList = formats ?? [
            ["id": "wav", "label": "WAV", "available": true, "ext": "wav", "mime": "audio/wav"],
            ["id": "m4a", "label": "M4A (AAC)", "available": true, "ext": "m4a", "mime": "audio/mp4"],
            ["id": "mp3", "label": "MP3", "available": false, "ext": "mp3", "mime": "audio/mpeg", "reason": "needs ffmpeg or lame"],
            ["id": "pcm", "label": "PCM", "available": true, "ext": "pcm", "mime": "audio/L16"],
        ]
        let formatsData = PlaygroundFixtures.json(["formats": formatList])
        MockURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/v2/formats")
            return PlaygroundFixtures.respond(request, status: 200, body: formatsData)
        }
    }

    /// Answers one /v1/audio/speech with a short WAV, echoing the voice
    /// the request asked for; records the request body.
    private func stubSpeech(record: SendableBox<[[String: Any]]>? = nil, delay: TimeInterval = 0) {
        MockURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/v1/audio/speech")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = (try? JSONSerialization.jsonObject(with: PlaygroundFixtures.body(of: request))) as? [String: Any] ?? [:]
            record?.mutate { $0.append(body) }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let headers = [
                "Content-Type": "audio/wav",
                "X-Myna-Engine": "kokoro",
                "X-Myna-Voice": body["voice"] as? String ?? "af_heart",
                "X-Myna-Duration-S": "0.25",
                "X-Myna-Sample-Rate": "24000",
                "X-Myna-Render-Ms": "321",
            ]
            return PlaygroundFixtures.respond(request, status: 200, headers: headers, body: PlaygroundFixtures.tone(seconds: 0.25))
        }
    }

    // MARK: - engine and voices

    func testRefreshReadsEngineVoicesAndFormats() async {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        XCTAssertEqual(model.engineState, .ready)
        XCTAssertEqual(model.engine?.name, "Kokoro")
        XCTAssertEqual(model.voices.map(\.id), ["af_heart", "af_bella", "am_adam"])
        XCTAssertEqual(model.voiceId, "af_bella", "defaults to the user's own voice")
        XCTAssertEqual(model.formats.map(\.id), ["wav", "m4a", "mp3"], "raw PCM isn't offered as a file")
        XCTAssertTrue(model.honoursSpeed)
    }

    func testVoiceFallsBackToEngineDefault() async {
        let model = makeModel(preferredVoice: "voice_from_another_engine")
        stubRefresh()
        await model.refresh()
        XCTAssertEqual(model.voiceId, "af_heart")
    }

    func testUnreachableDaemonLeavesWAVOnly() async {
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.engineState, .unreachable)
        XCTAssertTrue(model.voices.isEmpty)
        XCTAssertEqual(model.formats.map(\.id), ["wav"])
    }

    func testOneVoiceEngineNamesTakesAfterTheEngine() async {
        let model = makeModel()
        let oneVoice = PlaygroundFixtures.json([
            "voices": [["id": "chatterbox", "label": "Built-in voice", "lang": "en", "default": true]],
        ])
        stubRefresh(voices: oneVoice)
        await model.refresh()
        XCTAssertEqual(model.voiceId, "chatterbox")
        XCTAssertEqual(model.takeVoiceLabel(voice: "chatterbox", engineId: "kokoro"), "Kokoro")
        XCTAssertEqual(
            model.takeVoiceLabel(voice: "chatterbox", engineId: "another"), "Built-in voice",
            "a take from an engine that isn't the one shown keeps its own label")
    }

    func testQuickSaveUsesLastFormatOnlyIfStillAvailable() async {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        XCTAssertEqual(model.quickSaveFormat.id, "wav")
        defaults.set("m4a", forKey: PlaygroundModel.saveFormatKey)
        XCTAssertEqual(model.quickSaveFormat.id, "m4a")
        defaults.set("mp3", forKey: PlaygroundModel.saveFormatKey)
        XCTAssertEqual(model.quickSaveFormat.id, "wav", "MP3 is unavailable on this Mac")
    }

    // MARK: - generate

    func testGenerateSendsTextVoiceSpeedAndKeepsTheTake() async throws {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        let sent = SendableBox<[[String: Any]]>([])
        stubSpeech(record: sent)
        model.draft.text = "Hello from the playground."
        model.speed = 1.25
        model.generate()
        XCTAssertNotNil(model.job)
        await playgroundWait { model.job == nil }

        let request = try XCTUnwrap(sent.value.first)
        XCTAssertEqual(request["input"] as? String, "Hello from the playground.")
        XCTAssertEqual(request["voice"] as? String, "af_bella")
        XCTAssertEqual(request["response_format"] as? String, "wav")
        XCTAssertEqual(request["speed"] as? Double, 1.25)

        let take = try XCTUnwrap(model.store.takes.first)
        XCTAssertEqual(model.store.takes.count, 1)
        XCTAssertEqual(take.text, "Hello from the playground.")
        XCTAssertEqual(take.voice, "af_bella")
        XCTAssertEqual(take.voiceLabel, "Bella")
        XCTAssertEqual(take.engine, "kokoro")
        XCTAssertEqual(take.speed, 1.25)
        XCTAssertEqual(take.renderMs, 321)
        XCTAssertEqual(take.durationS, 0.25)
        XCTAssertNil(take.groupId)
        XCTAssertEqual(model.selectedTakeId, take.id)
        XCTAssertNil(model.notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.audioURL(for: take).path))
    }

    func testSpeedIsLeftOutForEnginesThatIgnoreIt() async throws {
        let model = makeModel()
        stubRefresh(nativeSpeed: false)
        await model.refresh()
        XCTAssertFalse(model.honoursSpeed)
        let sent = SendableBox<[[String: Any]]>([])
        stubSpeech(record: sent)
        model.draft.text = "Fixed pace."
        model.speed = 1.5
        model.generate()
        await playgroundWait { model.job == nil }
        XCTAssertNil(try XCTUnwrap(sent.value.first)["speed"])
        XCTAssertNil(model.store.takes.first?.speed)
    }

    func testCompareRendersEachVoiceIntoOneGroup() async throws {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        let sent = SendableBox<[[String: Any]]>([])
        for _ in 0..<3 { stubSpeech(record: sent) }
        model.draft.text = "Same words, three voices."
        model.toggleCompareVoice("af_heart")
        model.toggleCompareVoice("am_adam")
        model.toggleCompareVoice("af_bella")
        model.compare()
        await playgroundWait { model.job == nil }

        XCTAssertEqual(sent.value.compactMap { $0["voice"] as? String }, ["af_heart", "am_adam", "af_bella"])
        XCTAssertEqual(model.store.takes.count, 3)
        let groups = Set(model.store.takes.map(\.groupId))
        XCTAssertEqual(groups.count, 1)
        XCTAssertNotNil(groups.first ?? nil)
        let sections = PlaygroundTakeSection.sections(from: model.store.takes)
        guard case .comparison(_, let takes) = try XCTUnwrap(sections.first) else { return XCTFail("expected a comparison") }
        XCTAssertEqual(takes.map(\.voice), ["af_heart", "am_adam", "af_bella"])
    }

    func testCompareNeedsTwoVoicesAndCapsAtFour() async {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        model.draft.text = "Hi."
        model.toggleCompareVoice("af_heart")
        model.compare()
        XCTAssertNil(model.job, "one voice is not a comparison")

        for id in ["a", "b", "c", "d", "e"] { model.toggleCompareVoice(id) }
        XCTAssertEqual(model.compareVoiceIds.count, PlaygroundModel.maxCompareVoices)
        model.toggleCompareVoice("af_heart")
        XCTAssertFalse(model.compareVoiceIds.contains("af_heart"), "toggling again removes it")
    }

    func testCancelStopsWaitingAndKeepsNothing() async {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        stubSpeech(delay: 0.6)
        model.draft.text = "This one gets cancelled."
        model.generate()
        XCTAssertNotNil(model.job)
        try? await Task.sleep(nanoseconds: 100_000_000)
        model.cancel()
        XCTAssertNil(model.job)
        try? await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(model.store.takes.isEmpty)
        XCTAssertNil(model.notice, "cancelling isn't an error")
    }

    func testEngineDownBecomesANoticeWithAWayForward() async {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        MockURLProtocol.enqueue { request in
            let body = PlaygroundFixtures.json([
                "error": ["message": "engine down", "type": "server_error", "code": "engine_down"],
            ])
            return PlaygroundFixtures.respond(request, status: 503, body: body)
        }
        model.draft.text = "Nobody home."
        model.generate()
        await playgroundWait { model.job == nil }
        XCTAssertTrue(model.store.takes.isEmpty)
        XCTAssertEqual(model.notice?.action, .openEngine)
        XCTAssertEqual(model.notice?.kind, .error)
    }

    func testGenerateIsBlockedForEmptyAndOverlongText() {
        let model = makeModel()
        XCTAssertNotNil(model.generateBlocker(for: PlaygroundText.stats(for: "  ", speed: 1)))
        let long = String(repeating: "a ", count: PlaygroundText.syncCharacterLimit)
        XCTAssertNotNil(model.generateBlocker(for: PlaygroundText.stats(for: long, speed: 1)))
        XCTAssertNil(model.generateBlocker(for: PlaygroundText.stats(for: "Fine.", speed: 1)))

        model.draft.text = long
        model.generate()
        XCTAssertNil(model.job, "an overlong text never reaches the daemon")
    }

    // MARK: - takes

    func testDeletingTheSelectedTakeClearsSelection() async throws {
        let model = makeModel()
        let take = try await model.store.add(PlaygroundFixtures.draft())
        model.select(take)
        model.delete([take])
        XCTAssertNil(model.selectedTakeId)
        XCTAssertTrue(model.store.takes.isEmpty)
        XCTAssertFalse(model.toggleSelectedPlayback(), "Space does nothing without a selected take")
    }

    func testUseTextAndVoiceOfATake() async throws {
        let model = makeModel()
        stubRefresh()
        await model.refresh()
        let take = try await model.store.add(PlaygroundFixtures.draft(text: "Again, please.", voice: "am_adam"))
        model.useText(of: take)
        model.useVoice(of: take)
        XCTAssertEqual(model.draft.text, "Again, please.")
        XCTAssertEqual(model.voiceId, "am_adam")
    }

    // MARK: - dropped files

    func testDroppedMarkdownIsFlattened() throws {
        let model = makeModel()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.md")
        try Data("# Title\n\nSome **bold** words.".utf8).write(to: file)
        let plain = directory.appendingPathComponent("plain.txt")
        try Data("Plain text.".utf8).write(to: plain)
        XCTAssertEqual(model.textForDroppedFiles([file, plain]), "Title\n\nSome bold words.\n\nPlain text.")
        XCTAssertNil(model.notice)
    }

    func testOversizedDropPointsToStudio() throws {
        let model = makeModel()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("book.txt")
        try Data(repeating: 0x61, count: PlaygroundText.maxDroppedFileBytes + 1).write(to: file)
        XCTAssertNil(model.textForDroppedFiles([file]))
        XCTAssertEqual(model.notice?.action, .openStudio)
    }
}
