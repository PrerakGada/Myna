// StudioSnapshotTests.swift — draws Studio offscreen to PNGs so its layout
// can be looked at without opening the app.
//
// Skipped unless a folder is given:
//
//   TEST_RUNNER_STUDIO_SNAPSHOT_DIR=/tmp/shots xcodebuild test … \
//     -only-testing:MynaTests/StudioSnapshotTests
//
// The views are the real ones, in a window that is never shown, fed by
// models over a stubbed daemon. It asserts only that nothing is wider than
// the space it's given; the pictures are for a person.
import AppKit
import SwiftUI
import XCTest

@testable import Myna

@MainActor
final class StudioSnapshotTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8794")!
    private var output: URL!
    private var dir: URL!
    private var suiteName = ""

    private let minimumWidth = DashboardDesign.minWindowWidth - DashboardDesign.sidebarWidth - 1
    private let defaultWidth = DashboardDesign.windowWidth - DashboardDesign.sidebarWidth - 1

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["STUDIO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_STUDIO_SNAPSHOT_DIR to write snapshots")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "studio-snapshot-\(UUID().uuidString)"
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        if let dir { try? FileManager.default.removeItem(at: dir) }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - stubbed daemon

    private static func json(_ object: Any) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func engine(nativeSpeed: Bool) -> [String: Any] {
        [
            "id": "kokoro", "name": "Kokoro", "maker": "m", "tagline": "t", "description": "d", "repo": "r",
            "params": "82M", "languages": ["English"], "license": "Apache 2.0", "credit": NSNull(),
            "badge": NSNull(), "download_mb": 300, "sample_rate": 24_000, "native_speed": nativeSpeed,
            "cloning": false, "voices": [["id": "af_heart", "label": "Heart"]], "default_voice": "af_heart",
            "stats": [
                "first_word_s": 0.1, "stream_first_s": NSNull(), "speed_x": 40.0,
                "peak_memory_mb": 3_000.0, "word_error_pct": 4.0, "measured_on": "M5",
            ],
            "active": true, "state": "installed", "progress": NSNull(), "downloaded_mb": NSNull(),
            "total_mb": NSNull(), "disk_mb": 372.0, "error": NSNull(),
        ]
    }

    /// Answers by path, so concurrent requests can arrive in any order.
    private func serve(_ count: Int, jobs: [[String: Any]], nativeSpeed: Bool = true) {
        let routes: [String: Data] = [
            "/v2/renders": Self.json(["renders": jobs]),
            "/v2/voices": Self.json(["engine": "kokoro", "voices": [
                ["id": "af_heart", "label": "Heart (female)", "lang": "en-us", "default": true],
                ["id": "am_michael", "label": "Michael (male)", "lang": "en-us", "default": false],
            ]]),
            "/v2/engines": Self.json(["active": "kokoro", "engines": [Self.engine(nativeSpeed: nativeSpeed)]]),
            "/v2/formats": Self.json(["formats": [
                ["id": "wav", "label": "WAV", "available": true, "ext": "wav", "mime": "audio/wav"],
                ["id": "m4a", "label": "M4A (AAC)", "available": true, "ext": "m4a", "mime": "audio/mp4"],
                ["id": "mp3", "label": "MP3", "available": false, "ext": "mp3", "mime": "audio/mpeg",
                 "reason": "needs ffmpeg or lame"],
                ["id": "aac", "label": "AAC (ADTS)", "available": true, "ext": "aac", "mime": "audio/aac"],
                ["id": "flac", "label": "FLAC", "available": true, "ext": "flac", "mime": "audio/flac"],
                ["id": "opus", "label": "Ogg Opus", "available": false, "ext": "opus", "mime": "audio/ogg",
                 "reason": "needs ffmpeg with libopus"],
            ]]),
        ]
        for _ in 0..<count {
            MockURLProtocol.enqueue { request in
                let body = routes[request.url?.path ?? ""] ?? Data("{}".utf8)
                // swiftlint:disable:next force_unwrapping
                return (.make(url: request.url!, status: 200), body)
            }
        }
    }

    private func makeLibrary() -> StudioLibrary {
        StudioLibrary(
            client: RenderClient(baseURL: baseURL, session: MockURLProtocol.session()),
            requests: StudioRequestStore(directory: dir.appendingPathComponent("requests"))
        )
    }

    private func makeComposer() throws -> StudioComposer {
        StudioComposer(
            client: DaemonClient(baseURL: baseURL, session: MockURLProtocol.session()),
            settings: SettingsViewModel(store: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))),
            history: HistoryStore(directory: dir.appendingPathComponent("history"), fileName: "history.json")
        )
    }

    /// A minute of silence as a WAV, so the player has a real file.
    private func silentWAV() throws -> URL {
        let rate: UInt32 = 8_000
        let samples = Int(rate) * 60
        var data = Data("RIFF".utf8)
        func le<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        le(UInt32(36 + samples * 2))
        data.append(Data("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(rate); le(rate * 2); le(UInt16(2)); le(UInt16(16))
        data.append(Data("data".utf8))
        le(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        let url = dir.appendingPathComponent("r_done.wav")
        try data.write(to: url)
        return url
    }

    private func job(_ id: String, _ title: String, _ status: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "id": id, "title": title, "status": status, "source": "studio",
            "created_at": Date().timeIntervalSince1970 - 3_600, "engine": "kokoro", "voice": "af_heart",
            "speed": 1.0, "format": "m4a", "chars": 48_211, "words": 8_420, "chunks_total": 41, "chunks_done": 0,
            "progress": 0.0, "audio_s": 0.0, "preview": "It was late when the ferry finally came in, and the harbour lights…",
        ]
        for (key, value) in extra { fields[key] = value }
        return fields
    }

    private func libraryJobs(audio: URL) -> [[String: Any]] {
        let now = Date().timeIntervalSince1970
        let chapters = ["The Harbour", "The Ferry", "The Market", "A Letter from Home", "The Long Walk Back"]
            .enumerated().map { ["title": $1, "start_s": Double($0) * 11.5] }
        return [
            job("r_active", "A Week by the Sea", "rendering", [
                "created_at": now - 60, "chunks_done": 17, "progress": 0.41, "audio_s": 1_204.6, "eta_s": 95.0,
            ]),
            job("r_queued", "Quarterly report, final draft", "queued", ["created_at": now - 30]),
            job("r_done", "The Long Walk: a very long title that should truncate at the Dashboard's minimum width",
                "done", [
                    "created_at": now - 7_200, "finished_at": now - 7_000, "chunks_done": 41, "progress": 1.0,
                    "audio_s": 57.5, "file_path": audio.path, "bytes": 58_300_000, "chapters": chapters,
                ]),
            job("r_mp3", "Why cities flood", "done", [
                "created_at": now - 90_000, "finished_at": now - 89_000, "format": "mp3", "speed": 1.25,
                "audio_s": 812.0, "file_path": audio.path, "bytes": 6_500_000,
            ]),
            job("r_failed", "Notes from the conference", "failed", [
                "created_at": now - 100_000,
                "error": ["reason": "engine_error", "detail": "502 Bad Gateway from the voice engine at 127.0.0.1:8765"],
            ]),
            job("r_cancelled", "Draft chapter", "cancelled", ["created_at": now - 200_000]),
        ]
    }

    // MARK: - snapshots

    func test_library_with_every_state_and_the_player() async throws {
        let audio = try silentWAV()
        let jobs = libraryJobs(audio: audio)
        serve(12, jobs: jobs)
        let library = makeLibrary()
        library.requests.save(RenderRequest(title: "Notes", text: "x"), for: "r_failed")
        await library.refresh()
        let player = StudioPlayer()
        let doneJob = try XCTUnwrap(library.jobs.first { $0.id == "r_done" })
        player.play(doneJob, from: 25)
        player.pause()
        let composer = try makeComposer()

        for (width, name) in [(minimumWidth, "studio-library-minimum"), (defaultWidth, "studio-library-default")] {
            let pane = StudioLibraryPane(library: library, player: player, composer: composer, expandedId: "r_done")
            try snapshot(pane, width: width, height: width == minimumWidth ? 600 : 740, name: name)
        }
        player.close()
    }

    func test_empty_library() async throws {
        serve(4, jobs: [])
        let library = makeLibrary()
        await library.refresh()
        let pane = StudioLibraryPane(library: library, player: StudioPlayer(), composer: try makeComposer())
        try snapshot(pane, width: minimumWidth, height: 600, name: "studio-empty-minimum")
    }

    func test_review_sheet_for_a_book() async throws {
        serve(6, jobs: [])
        let library = makeLibrary()
        let composer = try makeComposer()
        let chapter = String(repeating: "The rain fell on the harbour all morning and nobody minded much. ", count: 40)
        var sections = [ImportedSection(title: "Contents", text: "One Two Three Four")]
        sections += (1...14).map { ImportedSection(title: "Chapter \($0): Somewhere Along the Coast", text: chapter) }
        sections.append(ImportedSection(title: "Notes", text: chapter, includedByDefault: false))
        composer.begin(document: ImportedDocument(
            title: "A Week by the Sea", sections: sections, kind: .epub, origin: "A Week by the Sea.epub"))
        await composer.loadContext(library: library)
        let sheet = StudioComposerSheet(composer: composer, library: library, onChooseFiles: {}, onClose: {})
        try snapshot(sheet, width: StudioComposerSheet.width, height: StudioComposerSheet.height, name: "studio-review-book")
        // Everything below the fold, unscrolled.
        try snapshot(StudioReviewView(composer: composer), width: StudioComposerSheet.width, height: 900,
                     name: "studio-review-book-full")
    }

    func test_review_sheet_for_pasted_text_on_a_fixed_speed_engine() async throws {
        serve(6, jobs: [], nativeSpeed: false)
        let library = makeLibrary()
        let composer = try makeComposer()
        composer.startPaste(text: "A Short Essay\n\n" + String(repeating: "Every sentence here is plain. ", count: 80))
        composer.continueFromPaste()
        await composer.loadContext(library: library)
        let sheet = StudioComposerSheet(composer: composer, library: library, onChooseFiles: {}, onClose: {})
        try snapshot(sheet, width: StudioComposerSheet.width, height: StudioComposerSheet.height, name: "studio-review-pasted")
    }

    func test_paste_and_import_error_stages() throws {
        let composer = try makeComposer()
        let library = makeLibrary()
        composer.startPaste()
        let paste = StudioComposerSheet(composer: composer, library: library, onChooseFiles: {}, onClose: {})
        try snapshot(paste, width: StudioComposerSheet.width, height: StudioComposerSheet.height, name: "studio-paste")

        composer.startFiles([URL(fileURLWithPath: "/tmp/scan.pdf")])
        composer.cancelWork()
        composer.error = StudioImportError.noTextLayer("scan.pdf").localizedDescription
        let failed = StudioComposerSheet(composer: composer, library: library, onChooseFiles: {}, onClose: {})
        try snapshot(failed, width: StudioComposerSheet.width, height: StudioComposerSheet.height, name: "studio-import-error")
    }

    private func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
        let root = view
            .frame(width: width, height: height)
            .background(DashboardDesign.surface)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5, "\(name): nothing is wider than its space")

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let file = output.appendingPathComponent("\(name).png")
        try png.write(to: file)
        print("snapshot: \(file.path) \(Int(width))×\(Int(height))")
        window.close()
    }
}
