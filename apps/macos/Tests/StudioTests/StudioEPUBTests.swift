// StudioEPUBTests.swift — EPUBs assembled from files by the test and zipped
// with ditto, the same tool the importer unzips with.
import XCTest

@testable import Myna

final class StudioEPUBTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private static let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """

    private static func xhtml(_ title: String, _ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(title)</title><link rel="stylesheet" href="../style.css"/></head>
        <body>\(body)</body></html>
        """
    }

    private static let words = "The lamps were lit early that night because the fog came in off the sea "
        + "and settled over the town like a second roof."

    /// Writes `files` (relative path → contents) and zips them into an EPUB.
    private func makeEPUB(_ name: String, files: [String: String]) throws -> URL {
        let root = dir.appendingPathComponent(name + "-src", isDirectory: true)
        var all = files
        all["mimetype"] = "application/epub+zip"
        all["META-INF/container.xml"] = Self.container
        for (path, contents) in all {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let epub = dir.appendingPathComponent(name + ".epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--sequesterRsrc", root.path, epub.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return epub
    }

    // MARK: - EPUB 3

    private func epub3Files(chapterOne: String? = nil) -> [String: String] {
        let opf = """
            <?xml version="1.0" encoding="utf-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fog Over Town</dc:title></metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1" href="text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1b" href="text/c1b.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
                <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
                <item id="css" href="style.css" media-type="text/css"/>
              </manifest>
              <spine>
                <itemref idref="cover"/><itemref idref="nav"/><itemref idref="c1"/><itemref idref="c1b"/>
                <itemref idref="c2"/><itemref idref="notes" linear="no"/>
              </spine>
            </package>
            """
        let nav = Self.xhtml("Contents", """
            <nav epub:type="toc"><h1>Contents</h1><ol>
              <li><a href="text/chapter%201.xhtml">One: The&#160;Start</a></li>
              <li><a href="text/c2.xhtml#c2">Two: <em>The Middle</em></a>
                <ol><li><a href="text/c2.xhtml#s1">A subsection</a></li></ol></li>
            </ol></nav>
            """)
        let chapterOneBody = chapterOne ?? """
            <h1>Chapter 1</h1>
            <p>It began with a footnote<a epub:type="noteref" href="#n1">1</a> and \
            <span epub:type="pagebreak" id="p5" title="5">5</span>more text&nbsp;here<sup>2</sup>.</p>
            <p>\(Self.words)</p>
            <aside epub:type="footnote" id="n1"><p>This note should not be read inline.</p></aside>
            """
        return [
            "OEBPS/content.opf": opf,
            "OEBPS/nav.xhtml": nav,
            "OEBPS/style.css": "p { margin: 0 }",
            "OEBPS/text/cover.xhtml": Self.xhtml("Cover", "<div><p>Fog Over Town</p><p>by Nobody In Particular</p></div>"),
            "OEBPS/text/chapter 1.xhtml": Self.xhtml("One", chapterOneBody),
            "OEBPS/text/c1b.xhtml": Self.xhtml("One, continued", "<p>Chapter one continues in a second file.</p>"),
            "OEBPS/text/c2.xhtml": Self.xhtml("Two", """
                <section id="c2"><h1>Chapter 2</h1><p>\(Self.words)</p>
                <h2 id="s1">A subsection</h2><p>\(Self.words)</p>
                <table><tr><td>Cell A</td><td>Cell B</td></tr></table></section>
                """),
            "OEBPS/text/notes.xhtml": Self.xhtml("Notes", "<h1>Notes</h1><p>1. The note text lives here.</p>"),
        ]
    }

    @MainActor
    func test_epub3_follows_nav_merges_continuations_and_switches_off_nonlinear() async throws {
        let url = try makeEPUB("fog", files: epub3Files())
        let doc = try await DocumentImporter.importFile(url)

        XCTAssertEqual(doc.title, "Fog Over Town")
        XCTAssertEqual(doc.kind, .epub)
        XCTAssertEqual(doc.sections.map(\.title), ["Cover", "One: The Start", "Two: The Middle", "Notes"])
        XCTAssertEqual(doc.sections.map(\.includedByDefault), [true, true, true, false])

        let one = doc.sections[1].text
        XCTAssertTrue(one.hasPrefix("Chapter 1.\n\nIt began with a footnote and more text here."), one)
        XCTAssertFalse(one.contains("should not be read"), "footnote asides are skipped")
        XCTAssertTrue(one.hasSuffix("Chapter one continues in a second file."), "continuation merged")

        let two = doc.sections[2].text
        XCTAssertTrue(two.contains("A subsection."), "sub-entries stay inside their chapter")
        XCTAssertTrue(two.contains("Cell A Cell B"))
    }

    @MainActor
    func test_malformed_chapter_falls_back_to_html_reader() async throws {
        let broken = "<h1>Chapter 1</h1><p>Unclosed line break<br> and an <b>unbalanced tag.</p><p>\(Self.words)</p>"
        let url = try makeEPUB("broken", files: epub3Files(chapterOne: broken))
        let contents = try EPUBImporter.read(url: url)
        XCTAssertFalse(contents.unparsed.isEmpty, "the XML reader rejects it")

        let doc = try await DocumentImporter.importFile(url)
        let one = try XCTUnwrap(doc.sections.first { $0.title == "One: The Start" })
        XCTAssertTrue(one.text.contains("Unclosed line break"), one.text)
        XCTAssertTrue(one.text.contains("fog came in off the sea"))
    }

    // MARK: - EPUB 2, one file, split at anchors

    func test_epub2_single_file_splits_at_ncx_anchors() throws {
        let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>One File Book</dc:title></metadata>
              <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="book" href="book.html" media-type="application/xhtml+xml"/>
              </manifest>
              <spine toc="ncx"><itemref idref="book"/></spine>
            </package>
            """
        let ncx = """
            <?xml version="1.0"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
              <navPoint id="a" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="book.html#ch1"/>
                <navPoint id="a1" playOrder="2"><navLabel><text>Deeper</text></navLabel><content src="book.html#d1"/></navPoint>
              </navPoint>
              <navPoint id="b" playOrder="3"><navLabel><text>Chapter Two</text></navLabel><content src="book.html#ch2"/></navPoint>
            </navMap></ncx>
            """
        let book = Self.xhtml("Book", """
            <p>Front words before any chapter.</p>
            <h2 id="ch1">Chapter One</h2><p>\(Self.words)</p><h3 id="d1">Deeper</h3><p>More of one.</p>
            <h2 id="ch2">Chapter Two</h2><p>Two begins. \(Self.words)</p>
            """)
        let url = try makeEPUB("onefile", files: [
            "OEBPS/content.opf": opf, "OEBPS/toc.ncx": ncx, "OEBPS/book.html": book,
        ])
        let contents = try EPUBImporter.read(url: url)
        XCTAssertEqual(contents.package.toc.map(\.title), ["Chapter One", "Deeper", "Chapter Two"])
        let doc = EPUBImporter.assemble(contents, fallbackTitle: "x", origin: "onefile.epub")
        XCTAssertEqual(doc.title, "One File Book")
        XCTAssertEqual(doc.sections.map(\.title), ["Book", "Chapter One", "Chapter Two"])
        XCTAssertEqual(doc.sections[0].text, "Front words before any chapter.")
        XCTAssertTrue(doc.sections[1].text.hasPrefix("Chapter One."))
        XCTAssertTrue(doc.sections[1].text.hasSuffix("More of one."))
        XCTAssertTrue(doc.sections[2].text.hasPrefix("Chapter Two.\n\nTwo begins."))
    }

    // MARK: - failures and the XHTML reader

    func test_not_a_zip_is_reported() throws {
        let url = dir.appendingPathComponent("fake.epub")
        try Data("not a zip".utf8).write(to: url)
        XCTAssertThrowsError(try EPUBImporter.read(url: url)) { error in
            guard case .brokenEPUB = error as? StudioImportError else {
                return XCTFail("expected brokenEPUB, got \(error)")
            }
        }
    }

    func test_xhtml_extractor_records_anchors_and_skips_ruby_and_scripts() throws {
        let data = Data(Self.xhtml("T", """
            <p id="start">漢<ruby>字<rt>かんじ</rt></ruby> text</p><script>alert(1)</script>
            <p id="second">Second &mdash; paragraph&hellip;</p>
            """).utf8)
        let result = try XCTUnwrap(XHTMLTextExtractor.extract(data))
        XCTAssertEqual(result.text, "漢字 text\n\nSecond — paragraph…")
        XCTAssertEqual(result.anchors["start"], 0)
        let offset = try XCTUnwrap(result.anchors["second"])
        let tail = String(bytes: Array(result.text.utf8)[offset...], encoding: .utf8) ?? ""
        XCTAssertTrue(tail.hasPrefix("Second"))
        XCTAssertEqual(result.title, "T")
    }
}
