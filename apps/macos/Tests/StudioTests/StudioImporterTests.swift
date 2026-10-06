// StudioImporterTests.swift — plain text, Markdown and the NSAttributedString
// formats. Fixtures are written by the tests themselves (RTF, DOCX and ODT
// through AppKit's own writers) so there are no binary files to keep in
// sync with the code.
import AppKit
import XCTest

@testable import Myna

final class StudioImporterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static let paragraph = "It was a bright cold day in April, and the clocks were striking thirteen. "
        + "Nobody in the town could say why, and nobody much wanted to ask about it."

    // MARK: - plain text

    func test_plain_text_without_chapters_is_one_section_titled_from_file() throws {
        let url = try write("field_notes.txt", "\(Self.paragraph)\n\n\(Self.paragraph)")
        let doc = try DocumentImporter.importOffMain(url, format: .plain)
        XCTAssertEqual(doc.title, "field notes")
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertEqual(doc.kind, .plainText)
    }

    func test_plain_text_splits_at_chapter_lines_and_merges_subtitles() throws {
        let text = """
        CHAPTER I.

        Down the Rabbit-Hole

        \(Self.paragraph)

        CHAPTER II. The Pool of Tears

        \(Self.paragraph)

        Chapter one was hard to write, she said, and nobody argued.
        """
        let doc = PlainTextImporter.parse(text, fallbackTitle: "Alice", kind: .plainText, origin: "a.txt")
        XCTAssertEqual(doc.sections.map(\.title), ["CHAPTER I: Down the Rabbit-Hole", "CHAPTER II. The Pool of Tears"])
        XCTAssertTrue(doc.sections[0].text.hasPrefix("CHAPTER I: Down the Rabbit-Hole.\n\nIt was a bright"))
        // The prose sentence that starts with "Chapter one" stays in chapter II.
        XCTAssertTrue(doc.sections[1].text.hasSuffix("nobody argued."))
    }

    func test_plain_text_trims_project_gutenberg_licence_and_reads_title() throws {
        let text = """
        The Project Gutenberg eBook of Tiny Tales

        Title: Tiny Tales
        Author: Somebody

        *** START OF THE PROJECT GUTENBERG EBOOK TINY TALES ***

        \(Self.paragraph)

        *** END OF THE PROJECT GUTENBERG EBOOK TINY TALES ***

        Section 1. General Terms of Use and Redistributing Project Gutenberg electronic works.
        """
        let doc = PlainTextImporter.parse(text, fallbackTitle: "pg123", kind: .plainText, origin: "pg123.txt")
        XCTAssertEqual(doc.title, "Tiny Tales")
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertFalse(doc.sections[0].text.contains("Gutenberg"))
        XCTAssertFalse(doc.sections[0].text.contains("Author"))
    }

    func test_plain_text_reflows_hard_wrapped_lines() {
        let wrapped = String(repeating: "The quick brown fox jumps over the lazy dog, again and again and\n", count: 12)
            + "the end."
        let doc = DocumentImporter.pastedText(wrapped)
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertFalse(doc.sections[0].text.contains("\n"))
        XCTAssertEqual(doc.kind, .pasted)
    }

    func test_pasted_text_title_is_its_first_line() {
        let doc = DocumentImporter.pastedText("A Short Title\n\n\(Self.paragraph)")
        XCTAssertEqual(doc.title, "A Short Title")
    }

    func test_read_text_falls_back_to_windows_latin() throws {
        let url = dir.appendingPathComponent("old.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: url)  // "café" in cp1252
        XCTAssertEqual(try DocumentImporter.readText(url), "café")
    }

    // MARK: - markdown

    func test_markdown_single_h1_becomes_title_and_h2s_split() {
        let markdown = """
        ---
        layout: post
        ---
        # The Handbook

        ## Getting started

        Install it with **one** command. See [the docs](https://example.com/docs) for _more_.

        ```bash
        brew install thing
        ```

        ### Details

        - first item
        - second item

        ## Going further

        ![diagram](img.png)
        A `code` word and a footnote[^1].

        [^1]: The note itself.
        """
        let doc = MarkdownImporter.parse(markdown, fallbackTitle: "readme", origin: "readme.md")
        XCTAssertEqual(doc.title, "The Handbook")
        XCTAssertEqual(doc.sections.map(\.title), ["Getting started", "Going further"])
        let first = doc.sections[0].text
        XCTAssertTrue(first.hasPrefix("Getting started.\n\nInstall it with one command. See the docs for more."))
        XCTAssertFalse(first.contains("brew install"), "fenced code is dropped")
        XCTAssertTrue(first.contains("Details."))
        XCTAssertTrue(first.contains("first item.\n\nsecond item."))
        let second = doc.sections[1].text
        XCTAssertTrue(second.contains("A code word and a footnote."))
        XCTAssertTrue(second.contains("The note itself."))
        XCTAssertFalse(second.contains("img.png"))
    }

    func test_markdown_front_matter_title_and_setext_headings() {
        let markdown = """
        ---
        title: "From Front Matter"
        ---
        Part one
        ========

        \(Self.paragraph)

        Part two
        ========

        | Name | Role |
        |------|------|
        | Ada  | Math |
        """
        let doc = MarkdownImporter.parse(markdown, fallbackTitle: "x", origin: "x.md")
        XCTAssertEqual(doc.title, "From Front Matter")
        XCTAssertEqual(doc.sections.map(\.title), ["Part one", "Part two"])
        XCTAssertTrue(doc.sections[1].text.contains("Ada, Math"))
        XCTAssertFalse(doc.sections[1].text.contains("---"))
    }

    func test_markdown_without_headings_is_one_section() {
        let doc = MarkdownImporter.parse("Just *some* notes.\nOn two lines.", fallbackTitle: "notes", origin: "n.md")
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertEqual(doc.sections[0].text, "Just some notes. On two lines.")
    }

    func test_markdown_keeps_snake_case_and_arithmetic() {
        XCTAssertEqual(MarkdownImporter.stripInline("use snake_case_names and 2 * 3 * 4"),
                       "use snake_case_names and 2 * 3 * 4")
    }

    // MARK: - rich text

    /// Two chapters with 20 pt headings over 12 pt body text, the shape
    /// a Word document's "Heading 1" style produces.
    private func richDocument() -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 20)]
        let out = NSMutableAttributedString()
        for (index, title) in ["The First Chapter", "The Second Chapter"].enumerated() {
            out.append(NSAttributedString(string: title + "\n", attributes: heading))
            out.append(NSAttributedString(string: "\(Self.paragraph) Chapter \(index + 1).\n", attributes: body))
            out.append(NSAttributedString(string: "\u{2022}\tA bulleted point\n", attributes: body))
        }
        return out
    }

    private func writeRich(_ name: String, type: NSAttributedString.DocumentType) throws -> URL {
        let doc = richDocument()
        let data = try doc.data(
            from: NSRange(location: 0, length: doc.length),
            documentAttributes: [.documentType: type, .title: "Rich Title"]
        )
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertTwoChapters(_ doc: ImportedDocument, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(doc.sections.map(\.title), ["The First Chapter", "The Second Chapter"], file: file, line: line)
        XCTAssertTrue(doc.sections[0].text.hasPrefix("The First Chapter.\n\nIt was a bright"), file: file, line: line)
        XCTAssertTrue(doc.sections[1].text.contains("Chapter 2."), file: file, line: line)
        XCTAssertTrue(doc.sections[0].text.contains("A bulleted point."), file: file, line: line)
        XCTAssertFalse(doc.sections[0].text.contains("\u{2022}"), file: file, line: line)
    }

    func test_rtf_headings_by_type_size_split_sections() throws {
        let url = try writeRich("story.rtf", type: .rtf)
        let doc = try DocumentImporter.importOffMain(url, format: .richText)
        assertTwoChapters(doc)
        XCTAssertEqual(doc.title, "Rich Title")
    }

    func test_docx_headings_by_type_size_split_sections() throws {
        let url = try writeRich("story.docx", type: .officeOpenXML)
        let doc = try DocumentImporter.importOffMain(url, format: .richText)
        assertTwoChapters(doc)
    }

    func test_odt_imports() throws {
        let url = try writeRich("story.odt", type: .openDocument)
        let doc = try DocumentImporter.importOffMain(url, format: .richText)
        assertTwoChapters(doc)
    }

    @MainActor
    func test_html_file_uses_header_levels_and_title() async throws {
        let html = """
        <html><head><title>Web Title</title><style>p{color:red}</style></head><body>
        <h1>Only Heading One</h1>
        <h2>Alpha</h2><p>\(Self.paragraph)</p>
        <h2>Beta</h2><p>\(Self.paragraph)</p><script>var x = 1;</script>
        </body></html>
        """
        let url = try write("page.html", html)
        let doc = try await DocumentImporter.importFile(url)
        XCTAssertEqual(doc.title, "Web Title")
        XCTAssertEqual(doc.sections.map(\.title), ["Alpha", "Beta"])
        XCTAssertFalse(doc.sections[1].text.contains("var x"))
    }

    @MainActor
    func test_unsupported_extension_throws() async throws {
        let url = try write("slides.key", "x")
        do {
            _ = try await DocumentImporter.importFile(url)
            XCTFail("expected unsupported")
        } catch let error as StudioImportError {
            XCTAssertEqual(error, .unsupported("slides.key"))
        }
    }

    @MainActor
    func test_several_files_combine_in_finder_order() async throws {
        let second = try write("Chapter 10.txt", Self.paragraph)
        let first = try write("Chapter 2.txt", Self.paragraph)
        let doc = try await DocumentImporter.importFiles([second, first])
        XCTAssertEqual(doc.sections.map(\.title), ["Chapter 2", "Chapter 10"])
        XCTAssertEqual(doc.origin, "2 files")
    }

    // MARK: - web

    func test_web_page_is_one_section_named_by_its_title() {
        let doc = DocumentImporter.webPage(title: "An Article", text: Self.paragraph, url: "https://news.example.com/a")
        XCTAssertEqual(doc.title, "An Article")
        XCTAssertEqual(doc.origin, "news.example.com")
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertEqual(doc.kind, .web)
    }
}
