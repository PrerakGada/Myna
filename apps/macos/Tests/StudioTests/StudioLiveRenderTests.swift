// StudioLiveRenderTests.swift — Studio end to end against a real daemon:
// import a file, review it, submit, poll until done, check the audio.
//
// Skipped unless STUDIO_LIVE_PORT names a daemon on 127.0.0.1 (a dev
// worktree's, never the user's own). Synthesis goes to whatever engine
// that daemon talks to, so this takes real seconds. Run it with:
//   TEST_RUNNER_STUDIO_LIVE_PORT=8794 xcodebuild test … \
//     -only-testing:MynaTests/StudioLiveRenderTests
import AVFoundation
import XCTest

@testable import Myna

@MainActor
final class StudioLiveRenderTests: XCTestCase {
    private var dir: URL!
    private var port: String!

    override func setUp() async throws {
        guard let port = ProcessInfo.processInfo.environment["STUDIO_LIVE_PORT"], !port.isEmpty else {
            throw XCTSkip("Set STUDIO_LIVE_PORT to run against a live daemon")
        }
        self.port = port
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private static let chapters = [
        ("The Harbour", "Rain fell on the harbour all morning, and the boats sat low in the grey water. "
            + "The fishermen mended their nets under the awning of the old ice house and argued, as they "
            + "always did, about the price of diesel and whether the season would turn before the month was out."),
        ("The Ferry", "The ferry was late again, which surprised no one. The queue of cars stretched back past "
            + "the chapel to the bend where the school used to stand, and the drivers stood by their doors, "
            + "talking across the roofs, in no particular hurry to be anywhere else."),
        ("The Market", "By Thursday the sun came out, and the whole town seemed to exhale at once. The market "
            + "filled by nine. Someone was selling honey from the hills, someone else was selling the same "
            + "honey for a little more, and everybody knew, and nobody minded."),
    ]

    private func writeEPUB() throws -> URL {
        let root = dir.appendingPathComponent("epub-src")
        func put(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try put("mimetype", "application/epub+zip")
        try put("META-INF/container.xml", """
            <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\
            </container>
            """)
        var manifest = #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        var spine = ""
        var nav = ""
        for (index, chapter) in Self.chapters.enumerated() {
            manifest += #"<item id="c\#(index)" href="c\#(index).xhtml" media-type="application/xhtml+xml"/>"#
            spine += #"<itemref idref="c\#(index)"/>"#
            nav += #"<li><a href="c\#(index).xhtml">\#(chapter.0)</a></li>"#
            try put("OEBPS/c\(index).xhtml", """
                <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(chapter.0)</title></head>\
                <body><h1>\(chapter.0)</h1><p>\(chapter.1)</p></body></html>
                """)
        }
        try put("OEBPS/nav.xhtml", """
            <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\
            <head><title>Contents</title></head><body><nav epub:type="toc"><ol>\(nav)</ol></nav></body></html>
            """)
        try put("OEBPS/content.opf", """
            <?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">\
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A Week by the Sea</dc:title></metadata>\
            <manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
            """)
        let epub = dir.appendingPathComponent("A Week by the Sea.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", root.path, epub.path]
        try zip.run()
        zip.waitUntilExit()
        return epub
    }

    private func makeComposer() -> StudioComposer {
        let suite = "studio-live-\(UUID().uuidString)"
        return StudioComposer(
            // swiftlint:disable:next force_unwrapping
            client: DaemonClient(baseURL: URL(string: "http://127.0.0.1:\(port!)")!),
            settings: SettingsViewModel(store: SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)),
            history: HistoryStore(directory: dir.appendingPathComponent("history"), fileName: "history.json")
        )
    }

    private func makeLibrary() -> StudioLibrary {
        StudioLibrary(
            // swiftlint:disable:next force_unwrapping
            client: RenderClient(baseURL: URL(string: "http://127.0.0.1:\(port!)")!),
            requests: StudioRequestStore(directory: dir.appendingPathComponent("requests"))
        )
    }

    /// Import → review (with the live voices and formats) → submit → poll.
    private func render(_ file: URL, format: String) async throws -> RenderJob {
        let composer = makeComposer()
        let library = makeLibrary()
        composer.startFiles([file])
        for _ in 0..<100 where composer.stage != .review {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(composer.stage, .review, composer.error ?? "import didn't finish")
        await composer.loadContext(library: library)
        XCTAssertFalse(composer.voices.isEmpty, "live voices loaded")
        XCTAssertNotNil(composer.engineName)
        composer.formatId = format
        let submitted = await composer.submit(to: library)
        XCTAssertTrue(submitted, composer.error ?? "")

        let deadline = Date().addingTimeInterval(300)
        var job = try XCTUnwrap(library.jobs.first)
        while job.status.isActive && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await library.refresh()
            job = try XCTUnwrap(library.jobs.first { $0.id == job.id })
            print("studio-live: \(job.id) \(job.status.rawValue) \(StudioJobPresentation.make(job: job, hasRequest: true).detail)")
        }
        XCTAssertEqual(job.status, .done, job.error.map { "\($0.reason): \($0.detail ?? "")" } ?? "timed out")
        XCTAssertFalse(library.requests.has(job.id), "the request record is pruned once done")
        return job
    }

    func test_epub_renders_to_m4a_with_chapters() async throws {
        let job = try await render(try writeEPUB(), format: "m4a")
        XCTAssertEqual(job.title, "A Week by the Sea")
        XCTAssertEqual(job.chapters?.map(\.title), Self.chapters.map(\.0))
        let url = try XCTUnwrap(job.fileURL)
        XCTAssertEqual(url.pathExtension, "m4a")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, job.audioS, accuracy: 1.0)
        XCTAssertGreaterThan(duration, 20)
        print("studio-live: EPUB file \(url.path) \(duration)s, chapters \(job.chapters ?? [])")
    }

    func test_markdown_renders_to_mp3() async throws {
        let markdown = dir.appendingPathComponent("notes.md")
        let body = "# Field Notes\n\n## Morning\n\n\(Self.chapters[0].1)\n\n## Evening\n\n\(Self.chapters[2].1)\n"
        try Data(body.utf8).write(to: markdown)
        let job = try await render(markdown, format: "mp3")
        XCTAssertEqual(job.title, "Field Notes")
        XCTAssertEqual(job.chapters?.map(\.title), ["Morning", "Evening"])
        print("studio-live: Markdown file \(job.filePath ?? "-") \(job.audioS)s")
    }

    func test_web_page_is_fetched_and_reviewed() async throws {
        let composer = makeComposer()
        composer.startWeb(url: "en.wikipedia.org/wiki/Myna")
        await composer.fetchURL()
        let fetched = try XCTUnwrap(composer.fetched, composer.error ?? "no article")
        XCTAssertEqual(composer.urlString, "https://en.wikipedia.org/wiki/Myna")
        XCTAssertGreaterThan(fetched.wordCount, 200)
        composer.continueFromWeb()
        XCTAssertEqual(composer.stage, .review)
        XCTAssertTrue(composer.cleanup.removeCitations)
        let request = try XCTUnwrap(composer.request)
        XCTAssertNotNil(request.text)
        XCTAssertNil(request.text?.range(of: #"\[\d+\]"#, options: .regularExpression), "citation markers removed")
        print("studio-live: web \(fetched.title) \(fetched.wordCount) words")
    }
}
