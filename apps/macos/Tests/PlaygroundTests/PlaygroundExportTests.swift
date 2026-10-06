// PlaygroundExportTests.swift — Save as never re-synthesizes: WAV is
// written as is, everything else goes through /v2/transcode. Also the
// takes-list grouping and the error banners.
import XCTest

@testable import Myna

final class PlaygroundExportTests: XCTestCase {

    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8766")!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        directory = PlaygroundFixtures.tempDirectory("export")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func makeRender() -> RenderClient {
        RenderClient(baseURL: baseURL, session: MockURLProtocol.session())
    }

    private func format(_ id: String, available: Bool = true, reason: String? = nil) -> AudioFormatInfo {
        AudioFormatInfo(id: id, label: id.uppercased(), available: available, ext: id, mime: "audio/\(id)", reason: reason)
    }

    // MARK: - plan

    func testWAVIsWrittenDirectlyEverythingElseIsTranscoded() {
        XCTAssertEqual(PlaygroundExport.plan(for: format("wav")), .writeWAV)
        XCTAssertEqual(PlaygroundExport.plan(for: format("WAV")), .writeWAV)
        XCTAssertEqual(PlaygroundExport.plan(for: format("m4a")), .transcode(format: "m4a"))
        XCTAssertEqual(PlaygroundExport.plan(for: format("mp3")), .transcode(format: "mp3"))
        XCTAssertEqual(PlaygroundExport.plan(for: format("flac")), .transcode(format: "flac"))
    }

    func testMenuFormatsPutWAVFirstAndDropRawPCM() {
        let fetched = [format("m4a"), format("pcm"), format("wav"), format("mp3", available: false, reason: "needs ffmpeg")]
        let menu = PlaygroundExport.menuFormats(fetched)
        XCTAssertEqual(menu.map(\.id), ["wav", "m4a", "mp3"])
        XCTAssertEqual(menu.last?.reason, "needs ffmpeg")
        XCTAssertFalse(menu.last?.available ?? true)
    }

    func testMenuFormatsAlwaysOfferWAV() {
        XCTAssertEqual(PlaygroundExport.menuFormats([format("m4a")]).map(\.id), ["wav", "m4a"])
        XCTAssertEqual(PlaygroundExport.menuFormats([]).map(\.id), ["wav"])
    }

    func testUnavailableFormatMenuTitleCarriesTheReason() {
        XCTAssertEqual(PlaygroundSaveMenu.itemTitle(format("m4a")), "M4A…")
        XCTAssertEqual(
            PlaygroundSaveMenu.itemTitle(format("mp3", available: false, reason: "needs ffmpeg or lame")),
            "MP3 — needs ffmpeg or lame")
    }

    // MARK: - encode

    private struct SeenRequest {
        var path: String?
        var query: String?
        var type: String?
        var body = Data()
    }

    func testEncodeWAVMakesNoRequest() async throws {
        // No handler queued: any request would fail with cannot-connect.
        let wav = PlaygroundFixtures.tone(seconds: 0.05)
        let out = try await PlaygroundExport.encode(wav: wav, as: format("wav"), using: makeRender())
        XCTAssertEqual(out, wav)
    }

    func testEncodeOtherFormatsTranscodeTheSameWAV() async throws {
        let wav = PlaygroundFixtures.tone(seconds: 0.05)
        let seen = SendableBox(SeenRequest())
        MockURLProtocol.enqueue { request in
            seen.value = SeenRequest(
                path: request.url?.path,
                query: request.url?.query,
                type: request.value(forHTTPHeaderField: "Content-Type"),
                body: PlaygroundFixtures.body(of: request)
            )
            return PlaygroundFixtures.respond(
                request, headers: ["Content-Type": "audio/mp4"], body: Data("m4a-bytes".utf8))
        }
        let out = try await PlaygroundExport.encode(wav: wav, as: format("m4a"), using: makeRender())
        XCTAssertEqual(out, Data("m4a-bytes".utf8))
        XCTAssertEqual(seen.value.path, "/v2/transcode")
        XCTAssertEqual(seen.value.query, "format=m4a")
        XCTAssertEqual(seen.value.type, "audio/wav")
        XCTAssertEqual(seen.value.body, wav, "the stored take is re-encoded, not re-rendered")
    }

    func testExportWritesTheEncodedFile() async throws {
        let source = directory.appendingPathComponent("t_source.wav")
        try PlaygroundFixtures.tone(seconds: 0.05).write(to: source)
        let destination = directory.appendingPathComponent("Out.flac")
        MockURLProtocol.enqueue { request in
            PlaygroundFixtures.respond(request, status: 200, body: Data("flac".utf8))
        }
        try await PlaygroundExport.export(source: source, as: format("flac"), to: destination, using: makeRender())
        XCTAssertEqual(try Data(contentsOf: destination), Data("flac".utf8))

        let wavDestination = directory.appendingPathComponent("Out.wav")
        try await PlaygroundExport.export(source: source, as: format("wav"), to: wavDestination, using: makeRender())
        XCTAssertEqual(try Data(contentsOf: wavDestination), try Data(contentsOf: source))
    }

    func testTranscodeRefusalBecomesAFormatNotice() async {
        MockURLProtocol.enqueue { request in
            let body = PlaygroundFixtures.json(["detail": ["ok": false, "reason": "format_unavailable", "detail": "needs ffmpeg"]])
            return PlaygroundFixtures.respond(request, status: 400, body: body)
        }
        do {
            _ = try await PlaygroundExport.encode(wav: Data(), as: format("mp3"), using: makeRender())
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? RenderAPIError, .formatUnavailable("needs ffmpeg"))
            let notice = PlaygroundErrors.notice(for: error)
            XCTAssertTrue(notice.message.contains("needs ffmpeg"))
            XCTAssertTrue(notice.message.contains("WAV always works"))
        }
    }

    // MARK: - drag / copy

    func testShareableFileHasReadableNameAndSameBytes() throws {
        let source = directory.appendingPathComponent("t_abc.wav")
        let wav = PlaygroundFixtures.tone(seconds: 0.05)
        try wav.write(to: source)
        let takeId = "t_test_\(UUID().uuidString.prefix(6))"
        let file = try XCTUnwrap(PlaygroundExport.shareableFile(source: source, takeId: takeId, fileName: "Hello there - Heart.wav"))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "Hello there - Heart.wav")
        XCTAssertEqual(try Data(contentsOf: file), wav)
        // Asking again reuses it.
        XCTAssertEqual(PlaygroundExport.shareableFile(source: source, takeId: takeId, fileName: "Hello there - Heart.wav"), file)
    }

    // MARK: - list grouping

    private func take(_ id: String, group: String? = nil, secondsAgo: Double) -> PlaygroundTake {
        PlaygroundTake(
            id: id, createdAt: Date(timeIntervalSinceNow: -secondsAgo), text: id, voice: "v", voiceLabel: "V",
            engine: nil, speed: nil, durationS: 1, renderMs: nil, bars: [], groupId: group)
    }

    func testSectionsGroupComparisonsInRenderOrder() {
        // Newest first, as the store keeps them.
        let takes = [
            take("single-new", secondsAgo: 1),
            take("c3", group: "g", secondsAgo: 2),
            take("c2", group: "g", secondsAgo: 3),
            take("c1", group: "g", secondsAgo: 4),
            take("single-old", secondsAgo: 5),
        ]
        let sections = PlaygroundTakeSection.sections(from: takes)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0], .single(takes[0]))
        guard case .comparison(let id, let members) = sections[1] else { return XCTFail("expected a comparison") }
        XCTAssertEqual(id, "g")
        XCTAssertEqual(members.map(\.id), ["c1", "c2", "c3"], "left to right in the order they were rendered")
        XCTAssertEqual(sections[2], .single(takes[4]))
    }

    func testLoneSurvivorOfAComparisonIsAPlainRow() {
        let lone = take("c1", group: "g", secondsAgo: 1)
        XCTAssertEqual(PlaygroundTakeSection.sections(from: [lone]), [.single(lone)])
    }

    func testSnippetCollapsesWhitespaceAndCuts() {
        var sample = take("x", secondsAgo: 0)
        sample = PlaygroundTake(
            id: "x", text: "Hello\n\n  there   friend", voice: "v", voiceLabel: "V",
            engine: nil, speed: nil, durationS: 1, renderMs: nil, bars: [])
        XCTAssertEqual(sample.snippet(), "Hello there friend")
        XCTAssertEqual(sample.snippet(limit: 7), "Hello t…")
    }

    // MARK: - error banners

    func testErrorNoticesSayWhatToDoNext() {
        XCTAssertEqual(PlaygroundErrors.notice(for: RenderAPIError.engineDown).action, .openEngine)
        XCTAssertTrue(PlaygroundErrors.notice(for: RenderAPIError.engineDown).message.contains("Restart"))
        XCTAssertEqual(PlaygroundErrors.notice(for: RenderAPIError.inputTooLong).action, .sendToStudio)
        XCTAssertEqual(PlaygroundErrors.notice(for: RenderAPIError.transport("refused")).action, .openEngine)
        XCTAssertEqual(PlaygroundErrors.notice(for: RenderAPIError.engineNotActive("")).action, .openEngine)
        XCTAssertTrue(PlaygroundErrors.notice(for: RenderAPIError.notFound).message.contains("older than the app"))
        XCTAssertTrue(PlaygroundErrors.notice(for: RenderAPIError.engineError("boom")).message.contains("another voice"))
        XCTAssertEqual(PlaygroundErrors.notice(for: RenderAPIError.engineDown).kind, .error)
    }
}
