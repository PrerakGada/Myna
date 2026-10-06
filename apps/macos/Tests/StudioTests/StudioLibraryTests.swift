// StudioLibraryTests.swift — Studio's view-model layer: how a RenderJob is
// presented, the duration estimate, the request the review builds, and
// the library against a stubbed daemon (MockURLProtocol, no sockets).
import XCTest

@testable import Myna

/// A RenderJob decoded from JSON, so tests only state what they care about.
func makeJob(_ overrides: [String: Any] = [:]) -> RenderJob {
    var fields: [String: Any] = [
        "id": "r_1", "title": "A Title", "status": "done", "source": "studio",
        "created_at": 1_790_700_000.0, "started_at": 1_790_700_001.0, "finished_at": 1_790_700_100.0,
        "engine": "kokoro", "voice": "af_heart", "speed": 1.0, "format": "m4a",
        "chars": 6_000, "words": 1_000, "chunks_total": 4, "chunks_done": 4, "progress": 1.0,
        "audio_s": 372.0, "eta_s": 0.0, "file_path": "/tmp/r_1.m4a", "bytes": 3_100_000,
        "chapters": NSNull(), "error": NSNull(), "preview": "It was late when…",
    ]
    for (key, value) in overrides { fields[key] = value }
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: fields)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(RenderJob.self, from: data)
}

func jobJSON(_ jobs: [[String: Any]]) -> Data {
    // swiftlint:disable:next force_try
    try! JSONSerialization.data(withJSONObject: ["renders": jobs])
}

final class StudioPresentationTests: XCTestCase {

    func test_queued_says_how_many_are_ahead() {
        let job = makeJob(["status": "queued", "chunks_done": 0, "progress": 0.0, "file_path": NSNull()])
        XCTAssertEqual(StudioJobPresentation.make(job: job, ahead: 0, hasRequest: true).detail, "Starting soon · 1,000 words")
        XCTAssertNil(StudioJobPresentation.make(job: job, hasRequest: true).progress, "no bar until it starts")
        let waiting = StudioJobPresentation.make(job: job, ahead: 2, hasRequest: true)
        XCTAssertTrue(waiting.detail.hasPrefix("Waiting for 2 renders ahead"))
        XCTAssertEqual(waiting.badge, "Queued")
        XCTAssertTrue(waiting.canCancel)
        XCTAssertFalse(waiting.canPlay)
    }

    func test_rendering_shows_parts_audio_and_eta() {
        let job = makeJob([
            "status": "rendering", "chunks_total": 41, "chunks_done": 17, "progress": 0.41,
            "audio_s": 1_204.6, "eta_s": 95.0, "file_path": NSNull(),
        ])
        let presentation = StudioJobPresentation.make(job: job, hasRequest: true)
        XCTAssertEqual(presentation.phase, .rendering)
        XCTAssertEqual(presentation.progress, 0.41)
        XCTAssertEqual(presentation.detail, "17 of 41 parts · 20m 5s of audio · about 1m 35s left")
        XCTAssertTrue(presentation.canCancel)
    }

    func test_rendering_without_eta_leaves_it_out() {
        let job = makeJob(["status": "rendering", "chunks_done": 1, "audio_s": 12.0, "eta_s": NSNull()])
        XCTAssertEqual(StudioJobPresentation.make(job: job, hasRequest: true).detail, "1 of 4 parts · 12s of audio")
    }

    func test_encoding_is_indeterminate() {
        let job = makeJob(["status": "encoding"])
        let presentation = StudioJobPresentation.make(job: job, hasRequest: true)
        XCTAssertTrue(presentation.showsIndeterminateProgress)
        XCTAssertNil(presentation.progress)
        XCTAssertTrue(presentation.detail.hasPrefix("Saving the M4A file"))
    }

    func test_done_lists_duration_size_format_voice_and_chapters() {
        let job = makeJob([
            "speed": 1.25,
            "chapters": [["title": "One", "start_s": 0.0], ["title": "Two", "start_s": 190.0]],
        ])
        let presentation = StudioJobPresentation.make(job: job, hasRequest: false)
        XCTAssertEqual(presentation.phase, .done)
        XCTAssertEqual(presentation.badge, "")
        XCTAssertTrue(presentation.canPlay)
        XCTAssertFalse(presentation.canRetry)
        for part in ["6m 12s", "3.1 MB", "M4A", "af_heart", "1.25×", "2 chapters"] {
            XCTAssertTrue(presentation.detail.contains(part), "\(part) in \(presentation.detail)")
        }
    }

    func test_failed_reasons_are_plain_and_retry_needs_the_request() {
        let interrupted = makeJob(["status": "failed", "error": ["reason": "interrupted", "detail": ""]])
        let withRecord = StudioJobPresentation.make(job: interrupted, hasRequest: true)
        XCTAssertEqual(withRecord.badge, "Failed")
        XCTAssertTrue(withRecord.failure?.hasPrefix("Myna's voice service stopped") == true)
        XCTAssertTrue(withRecord.canRetry)
        XCTAssertFalse(StudioJobPresentation.make(job: interrupted, hasRequest: false).canRetry)

        let engine = makeJob(["status": "failed", "error": ["reason": "engine_error", "detail": "502 from engine"]])
        XCTAssertEqual(StudioJobPresentation.failureText(engine), "The voice engine failed: 502 from engine")
        let switched = makeJob(["status": "failed", "error": ["reason": "engine_changed", "detail": NSNull()]])
        XCTAssertTrue(StudioJobPresentation.failureText(switched).contains("switched"))
        let unknown = makeJob(["status": "failed", "error": ["reason": "disk_full", "detail": NSNull()]])
        XCTAssertEqual(StudioJobPresentation.failureText(unknown), "Disk full")
    }

    func test_cancelled_can_be_retried_when_the_request_is_kept() {
        let job = makeJob(["status": "cancelled"])
        let presentation = StudioJobPresentation.make(job: job, hasRequest: true)
        XCTAssertEqual(presentation.phase, .cancelled)
        XCTAssertTrue(presentation.canRetry)
        XCTAssertFalse(presentation.canCancel)
    }

    func test_clock_and_file_name_formatting() {
        XCTAssertEqual(StudioFormat.clock(65), "1:05")
        XCTAssertEqual(StudioFormat.clock(3_723), "1:02:03")
        XCTAssertEqual(StudioFormat.formatLabel("opus"), "Ogg Opus")
        XCTAssertEqual(StudioFileActions.fileName(title: "Part 1/2: Intro", format: "m4a"), "Part 1-2- Intro.m4a")
        XCTAssertEqual(StudioFileActions.fileName(title: "  ...  ", format: "mp3"), "Myna recording.mp3")
        XCTAssertEqual(StudioFileActions.fileName(title: String(repeating: "x", count: 300), format: "wav").count, 124)
    }
}

final class StudioEstimateTests: XCTestCase {

    func test_seconds_scale_with_speed_and_include_pauses() {
        XCTAssertEqual(StudioEstimate.seconds(words: 160, speed: 1, wordsPerMinute: 160), 60, accuracy: 0.01)
        XCTAssertEqual(StudioEstimate.seconds(words: 160, speed: 2, wordsPerMinute: 160), 30, accuracy: 0.01)
        XCTAssertEqual(StudioEstimate.seconds(words: 0, speed: 1, wordsPerMinute: 160), 0)
        let total = StudioEstimate.totalSeconds(
            sectionWords: [160, 160, 160], speed: 1, wordsPerMinute: 160, pauseMs: 1_500)
        XCTAssertEqual(total, 183, accuracy: 0.01)
    }

    func test_pace_comes_from_finished_renders_on_the_same_engine_first() {
        let renders = [
            makeJob(["words": 1_800, "audio_s": 600.0]),                         // 180 wpm
            makeJob(["id": "r_2", "words": 2_000, "audio_s": 500.0, "speed": 1.25]), // 240 observed → 192 at 1×
            makeJob(["id": "r_3", "words": 900, "audio_s": 600.0, "engine": "soprano"]), // other engine
            makeJob(["id": "r_4", "words": 100, "audio_s": 20.0]),               // too short to trust
        ]
        let wpm = StudioEstimate.wordsPerMinute(renders: renders, engine: "kokoro", history: [])
        XCTAssertEqual(wpm, 186, accuracy: 0.01)
    }

    func test_pace_falls_back_to_completed_reads_then_default() {
        let reads = [
            ReadEvent(title: "a", voice: "v", words: 300, audioSeconds: 100, outcome: .completed),  // 180
            ReadEvent(title: "b", voice: "v", words: 300, audioSeconds: 50, outcome: .stopped),     // ignored
            ReadEvent(title: "c", voice: "v", speed: 1.5, words: 300, audioSeconds: 60, outcome: .completed),
        ]
        XCTAssertEqual(StudioEstimate.wordsPerMinute(renders: [], engine: "kokoro", history: reads), 180, accuracy: 0.01)
        XCTAssertEqual(StudioEstimate.wordsPerMinute(renders: [], engine: nil, history: []),
                       StudioEstimate.fallbackWordsPerMinute)
    }
}

@MainActor
final class StudioComposerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyDir: URL!

    override func setUp() async throws {
        suiteName = "studio-composer-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: historyDir)
    }

    private func makeComposer() -> StudioComposer {
        StudioComposer(
            client: DaemonClient(baseURL: URL(fileURLWithPath: "/dev/null"), session: MockURLProtocol.session()),
            settings: SettingsViewModel(store: SettingsStore(defaults: defaults)),
            history: HistoryStore(directory: historyDir, fileName: "history.json")
        )
    }

    private func section(_ id: Int, words: Int, included: Bool = true) -> StudioReviewSection {
        let text = Array(repeating: "word", count: words).joined(separator: " ")
        return StudioReviewSection(id: id, title: "S\(id)", text: text, words: words, skippable: false, included: included)
    }

    func test_one_included_section_is_sent_as_text() throws {
        let request = try XCTUnwrap(StudioComposer.buildRequest(
            title: "  ", fallbackTitle: "Imported", sections: [section(0, words: 5), section(1, words: 5, included: false)],
            choices: .init(voice: "af_heart", speed: 1.1, format: "mp3", pauseMs: 900)))
        XCTAssertEqual(request.title, "Imported")
        XCTAssertEqual(request.text, "word word word word word")
        XCTAssertNil(request.sections)
        XCTAssertNil(request.sectionPauseMs)
        XCTAssertEqual(request.format, "mp3")
        XCTAssertEqual(request.source, "studio")
        XCTAssertEqual(request.speed, 1.1)
    }

    func test_several_sections_are_sent_as_chapters_with_the_pause() throws {
        let request = try XCTUnwrap(StudioComposer.buildRequest(
            title: "Book", fallbackTitle: "x",
            sections: [section(0, words: 3), section(1, words: 0), section(2, words: 4)],
            choices: .init(voice: "", speed: nil, format: "m4a", pauseMs: 1_500)))
        XCTAssertEqual(request.sections?.map(\.title), ["S0", "S2"], "empty sections are never sent")
        XCTAssertNil(request.text)
        XCTAssertNil(request.voice, "no voice list → the engine's default")
        XCTAssertEqual(request.sectionPauseMs, 1_500)
    }

    func test_nothing_included_builds_nothing() {
        XCTAssertNil(StudioComposer.buildRequest(
            title: "t", fallbackTitle: "t", sections: [section(0, words: 3, included: false)],
            choices: .init(voice: "", speed: nil, format: "m4a", pauseMs: 0)))
    }

    func test_review_applies_defaults_and_keeps_user_switches_across_cleanups() {
        let composer = makeComposer()
        let body = Array(repeating: "Plenty of words in this chapter [1] to be well over the threshold.", count: 8)
            .joined(separator: " ")
        let document = ImportedDocument(
            title: "Book",
            sections: [
                ImportedSection(title: "Contents", text: "One Two Three"),
                ImportedSection(title: "Chapter 1", text: body),
                ImportedSection(title: "Chapter 2", text: body),
                ImportedSection(title: "Notes", text: body, includedByDefault: false),
            ],
            kind: .epub,
            origin: "book.epub"
        )
        composer.begin(document: document)
        XCTAssertEqual(composer.stage, .review)
        XCTAssertTrue(composer.cleanup.skipShortSections)
        XCTAssertTrue(composer.cleanup.removeCitations)
        XCTAssertEqual(composer.sections.map(\.included), [false, true, true, false])
        XCTAssertFalse(composer.sections[1].text.contains("[1]"))

        // The user switches chapter 2 off, then changes a cleanup: kept.
        composer.sections[2].included = false
        composer.cleanup.removeCitations = false
        XCTAssertEqual(composer.sections.map(\.included), [false, true, false, false])
        XCTAssertTrue(composer.sections[1].text.contains("[1]"))

        // Turning the short-section rule off only re-decides the short one.
        composer.cleanup.skipShortSections = false
        XCTAssertEqual(composer.sections.map(\.included), [true, true, false, false])
    }

    func test_paste_and_url_normalisation() {
        let composer = makeComposer()
        composer.startPaste(text: "   ")
        XCTAssertTrue(composer.isPresented)
        composer.continueFromPaste()
        XCTAssertEqual(composer.stage, .paste)
        XCTAssertNotNil(composer.error)
        XCTAssertEqual(StudioComposer.normalizedURL(" example.com/a "), "https://example.com/a")
        XCTAssertEqual(StudioComposer.normalizedURL("http://x.io"), "http://x.io")
    }
}

@MainActor
final class StudioLibraryTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8794")!
    private var storeDir: URL!

    override func setUp() async throws {
        MockURLProtocol.reset()
        storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-requests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try? FileManager.default.removeItem(at: storeDir)
    }

    private func makeLibrary() -> StudioLibrary {
        StudioLibrary(
            client: RenderClient(baseURL: baseURL, session: MockURLProtocol.session()),
            requests: StudioRequestStore(directory: storeDir)
        )
    }

    private func respond(_ status: Int, _ body: Data, check: (@Sendable (URLRequest) -> Void)? = nil) {
        MockURLProtocol.enqueue { request in
            check?(request)
            // swiftlint:disable:next force_unwrapping
            return (.make(url: request.url!, status: status), body)
        }
    }

    private static func jobDict(_ id: String, _ status: String, created: Double) -> [String: Any] {
        [
            "id": id, "title": id, "status": status, "source": "studio", "created_at": created,
            "engine": "kokoro", "voice": "af_heart", "speed": 1.0, "format": "m4a", "chars": 10, "words": 2,
            "chunks_total": 1, "chunks_done": 0, "progress": 0.0, "audio_s": 0.0,
        ]
    }

    func test_refresh_sorts_newest_first_and_reports_activity() async {
        respond(200, jobJSON([
            Self.jobDict("r_old", "done", created: 1), Self.jobDict("r_new", "rendering", created: 3),
            Self.jobDict("r_mid", "queued", created: 2),
        ]))
        let library = makeLibrary()
        await library.refresh()
        XCTAssertEqual(library.jobs.map(\.id), ["r_new", "r_mid", "r_old"])
        XCTAssertTrue(library.hasActiveJobs)
        XCTAssertTrue(library.loaded)
        XCTAssertNil(library.loadError)
        XCTAssertTrue(library.presentation(for: library.jobs[1]).detail.hasPrefix("Waiting for 1 render ahead"))
    }

    func test_unreachable_daemon_is_explained() async {
        let library = makeLibrary()
        await library.refresh()  // nothing enqueued → connection refused
        XCTAssertEqual(library.loadError, "Can't reach Myna's voice service. Check the Engine pane, then try again.")
        XCTAssertTrue(library.loaded)
    }

    func test_old_daemon_without_renders_is_explained() async {
        respond(404, Data(#"{"detail":"Not Found"}"#.utf8))
        let library = makeLibrary()
        await library.refresh()
        XCTAssertTrue(library.loadError?.contains("can't make audio files") == true)
    }

    func test_submit_keeps_the_request_until_the_job_is_done_and_retry_resubmits_it() async throws {
        let library = makeLibrary()
        let request = RenderRequest(title: "Book", sections: [RenderSection(title: "One", text: "Hello there.")],
                                    voice: "af_heart", format: "m4a", source: "studio", sectionPauseMs: 1_200)

        // Submit: POST, then the refresh it triggers.
        respond(201, try JSONSerialization.data(withJSONObject: Self.jobDict("r_a", "queued", created: 5))) { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v2/renders")
        }
        respond(200, jobJSON([Self.jobDict("r_a", "queued", created: 5)]))
        try await library.submit(request)
        XCTAssertTrue(library.requests.has("r_a"))
        XCTAssertEqual(library.requests.request(for: "r_a"), request)

        // It fails; retry sends the same body, then deletes the failed job.
        var failed = Self.jobDict("r_a", "failed", created: 5)
        failed["error"] = ["reason": "interrupted", "detail": ""]
        respond(200, jobJSON([failed]))
        await library.refresh()
        XCTAssertTrue(library.presentation(for: library.jobs[0]).canRetry)

        let sentBody = LockedBox<Data?>(nil)
        respond(201, try JSONSerialization.data(withJSONObject: Self.jobDict("r_b", "queued", created: 6))) { req in
            sentBody.value = req.httpBodyStreamData ?? req.httpBody
        }
        respond(200, jobJSON([Self.jobDict("r_b", "queued", created: 6), failed]))  // refresh after submit
        respond(200, Data(#"{"ok":true}"#.utf8)) { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            XCTAssertEqual(req.url?.path, "/v2/renders/r_a")
        }
        respond(200, jobJSON([Self.jobDict("r_b", "queued", created: 6)]))  // refresh after the action
        await library.retry(library.jobs[0])

        XCTAssertNil(library.actionError)
        XCTAssertEqual(library.jobs.map(\.id), ["r_b"])
        XCTAssertFalse(library.requests.has("r_a"))
        XCTAssertTrue(library.requests.has("r_b"))
        let resent = try JSONDecoder().decode(RenderRequest.self, from: try XCTUnwrap(sentBody.value))
        XCTAssertEqual(resent, request)

        // Done: the record is no longer needed.
        var done = Self.jobDict("r_b", "done", created: 6)
        done["file_path"] = "/tmp/r_b.m4a"
        respond(200, jobJSON([done]))
        await library.refresh()
        XCTAssertFalse(library.requests.has("r_b"))
    }

    func test_retry_without_a_record_says_why() async {
        let library = makeLibrary()
        await library.retry(makeJob(["id": "r_gone", "status": "failed", "title": "Lost"]))
        XCTAssertTrue(library.actionError?.contains("no longer has the text for “Lost”") == true)
    }

    func test_cancel_and_delete_update_the_list() async throws {
        let library = makeLibrary()
        respond(200, jobJSON([Self.jobDict("r_x", "rendering", created: 1)]))
        await library.refresh()

        respond(200, try JSONSerialization.data(withJSONObject: Self.jobDict("r_x", "cancelled", created: 1))) { req in
            XCTAssertEqual(req.url?.path, "/v2/renders/r_x/cancel")
        }
        respond(200, jobJSON([Self.jobDict("r_x", "cancelled", created: 1)]))
        await library.cancel(library.jobs[0])
        XCTAssertEqual(library.jobs.first?.status, .cancelled)
        XCTAssertFalse(library.hasActiveJobs)

        respond(200, Data(#"{"ok":true}"#.utf8))
        respond(200, jobJSON([]))
        await library.delete(library.jobs[0])
        XCTAssertTrue(library.jobs.isEmpty)
        XCTAssertNil(library.actionError)
    }

    func test_request_store_prunes_orphans_only_after_the_grace_period() throws {
        let store = StudioRequestStore(directory: storeDir)
        store.save(RenderRequest(title: "t", text: "x"), for: "r_fresh")
        store.save(RenderRequest(title: "t", text: "x"), for: "r_stale")
        store.save(RenderRequest(title: "t", text: "x"), for: "../escape")
        XCTAssertFalse(store.has("../escape"), "ids never become paths")
        let stalePath = storeDir.appendingPathComponent("r_stale.json").path
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-StudioRequestStore.orphanGrace - 60)], ofItemAtPath: stalePath)

        store.prune(done: [], known: [])
        XCTAssertTrue(store.has("r_fresh"))
        XCTAssertFalse(store.has("r_stale"))

        // A fresh store reads what's on disk.
        XCTAssertTrue(StudioRequestStore(directory: storeDir).has("r_fresh"))
    }
}

/// Thread-safe box for values a URLProtocol handler captures.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

private extension URLRequest {
    /// URLSession moves a POST body into a stream before URLProtocol sees it.
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
