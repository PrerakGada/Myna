// StudioPDFTests.swift — PDF cleanup rules on page strings, then one real
// PDF drawn with CoreText and given bookmarks through PDFKit, so the whole
// path (text layer → furniture → reflow → outline sections) is exercised.
import AppKit
import PDFKit
import XCTest

@testable import Myna

final class StudioPDFTests: XCTestCase {

    // MARK: - rules

    func test_page_number_lines() {
        for line in ["12", "- 12 -", "Page 12", "12 of 300", "xii", "Page 3 / 10", "[7]", "— 45 —"] {
            XCTAssertTrue(PDFTextCleaner.isPageNumberLine(line), line)
        }
        for line in ["12 Angry Men", "In 1999 it rained", "Chapter 12", "I think so", "12."] {
            XCTAssertFalse(PDFTextCleaner.isPageNumberLine(line), line)
        }
    }

    private static let openings = [
        "Morning came slowly over the hills and the valley below them all.",
        "The river was high that week after the long spring rains had gone.",
        "Nobody at the inn had seen the stranger arrive the night before it.",
        "She counted the coins twice and still came up one short of enough.",
        "The road north was closed, so they took the coast road instead now.",
        "By evening the wind had dropped and the stars were out over the bay.",
    ]

    private func bodyLines(_ page: Int) -> [String] {
        [
            Self.openings[page % Self.openings.count],
            "A line that repeats on every page but sits in the middle of it.",
            "Some ordinary words of body text that fill out the page a little.",
            "A line that repeats on every page but sits in the middle of it.",
            Self.openings[(page + 3) % Self.openings.count],
        ]
    }

    func test_running_headers_and_page_numbers_are_removed_but_body_repeats_kept() {
        let pages = (0..<6).map { page -> String in
            // Even and odd pages carry the header on different sides of the number.
            let header = page.isMultiple(of: 2) ? "\(page + 1)   THE LONG WALK" : "Chapter Three   \(page + 1)"
            return ([header] + bodyLines(page) + ["\(page + 1)"]).joined(separator: "\n")
        }
        let cleaned = PDFTextCleaner.stripPageFurniture(pages)
        for (index, page) in cleaned.enumerated() {
            XCTAssertFalse(page.contains("THE LONG WALK"), "page \(index)")
            XCTAssertFalse(page.contains("Chapter Three"), "page \(index)")
            XCTAssertFalse(page.hasSuffix("\n\(index + 1)"), "page \(index)")
            XCTAssertEqual(page.components(separatedBy: "sits in the middle").count - 1, 2, "page \(index)")
            XCTAssertTrue(page.hasPrefix(Self.openings[index]), "page \(index)")
            XCTAssertTrue(page.hasSuffix(Self.openings[(index + 3) % Self.openings.count]), "page \(index)")
        }
    }

    func test_short_documents_keep_repeated_lines() {
        // Under four pages there's no telling a header from a refrain.
        let pages = (1...3).map { "Refrain line\nBody \($0) text here.\nRefrain line" }
        XCTAssertTrue(PDFTextCleaner.stripPageFurniture(pages).allSatisfy { $0.hasPrefix("Refrain line") })
    }

    func test_join_pages_rejoins_hyphens_across_pages_and_reflows() {
        let pages = [
            "This is a long line of text which was set in a narrow column, like this.\nIt ends with a remark-",
            "able word and then keeps going for a while so that the paragraph is long.\nShort line.",
        ]
        let width = TextCleanup.typicalLineWidth(pages.flatMap { $0.components(separatedBy: "\n") })
        let text = PDFTextCleaner.joinPages(pages[...], width: width)
        XCTAssertTrue(text.contains("remarkable word"), text)
        XCTAssertFalse(text.contains("like this.\nIt ends"), "wrapped lines are joined")
    }

    func test_outline_sections_with_opening_pages_and_missing_heading_said() {
        let pages = [
            "A Tiny Book\nby Nobody",
            "First Chapter\nThe first chapter begins here and goes on for a little while longer.",
            "It continues on the next page of the first chapter with more words.",
            "This page has lost its heading to the running header rule, as many do.",
        ]
        let outline = [
            PDFTextCleaner.OutlineEntry(title: "Second Chapter", pageIndex: 3),
            PDFTextCleaner.OutlineEntry(title: "First Chapter", pageIndex: 1),
        ]
        let sections = PDFTextCleaner.sections(pages: pages, outline: outline, title: "A Tiny Book")
        XCTAssertEqual(sections.map(\.title), ["Opening pages", "First Chapter", "Second Chapter"])
        XCTAssertTrue(sections[1].text.hasPrefix("First Chapter\nThe first chapter"), "heading present, not repeated")
        XCTAssertTrue(sections[1].text.contains("next page of the first chapter"))
        XCTAssertTrue(sections[2].text.hasPrefix("Second Chapter.\n\nThis page has lost"))
    }

    func test_no_outline_is_one_section() {
        let sections = PDFTextCleaner.sections(pages: ["Just one page of words."], outline: [], title: "Memo")
        XCTAssertEqual(sections.map(\.title), ["Memo"])
    }

    // MARK: - a real PDF

    /// Wraps prose at ~68 characters, the way a page lays it out.
    private func wrap(_ text: String, width: Int = 68) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > width {
                lines.append(line)
                line = String(word)
            } else {
                line = line.isEmpty ? String(word) : line + " " + word
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Draws `pages` of text lines. `outline` is (title, page index); it is
    /// written by CoreGraphics because PDFKit's `write(to:)` on this macOS
    /// drops an outline set in memory.
    private func drawPDF(pages: [[String]], outline: [(String, Int)] = [], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("CoreGraphics couldn't open a PDF context")
        }
        let font = NSFont(name: "Helvetica", size: 11) ?? NSFont.systemFont(ofSize: 11)
        for lines in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 740
            for text in lines {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(line, context)
                y -= 18
            }
            context.endPDFPage()
        }
        if !outline.isEmpty {
            let children: [[String: Any]] = outline.map {
                [kCGPDFOutlineTitle as String: $0.0, kCGPDFOutlineDestination as String: $0.1 + 1]
            }
            CGPDFContextSetOutline(context, [kCGPDFOutlineChildren as String: children] as CFDictionary)
        }
        context.closePDF()
    }

    func test_generated_pdf_imports_with_outline_and_cleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tiny-book.pdf")

        let prose = [
            "Rain fell on the harbour all morning, and the boats sat low in the grey water while the "
                + "fishermen mended nets and argued about the price of diesel and the turning season.",
            "The ferry was late again, which surprised no one, and the queue of cars stretched back past "
                + "the chapel to the bend where the old school used to stand before the fire took it",
            "Down at the quay the gulls had found a crate of something nobody wanted to name, and the "
                + "harbourmaster stood over it with his hands in his pockets and said nothing at all.",
            "Inland the fields were flooded to the hedges, and the farmers who came to the market that "
                + "week talked of nothing but water, pumps, insurance and the government's promises.",
            "When the sun finally came out on the Thursday the whole town seemed to exhale at once, and "
                + "the cafe put its tables back on the pavement as if the winter had never happened.",
        ]
        var pages: [[String]] = []
        for page in 0..<5 {
            var body = wrap(prose[page])
            if page == 0 { body.insert("First Chapter", at: 0) }
            if page == 1 { body[body.count - 1] += " a remark-" }
            if page == 2 { body.insert("able thing happened next, which nobody saw coming at all.", at: 0) }
            pages.append(["A TINY BOOK"] + body + ["\(page + 1)"])
        }
        try drawPDF(pages: pages, outline: [("First Chapter", 0), ("Second Chapter", 3)], to: url)

        let imported = try DocumentImporter.importOffMain(url, format: .pdf)
        XCTAssertEqual(imported.title, "tiny-book")
        XCTAssertEqual(imported.kind, .pdf)
        XCTAssertEqual(imported.sections.map(\.title), ["First Chapter", "Second Chapter"])
        guard imported.sections.count == 2 else { return }
        let all = imported.sections.map(\.text).joined(separator: "\n")
        XCTAssertFalse(all.contains("A TINY BOOK"), all)
        XCTAssertTrue(all.contains("remarkable thing"), all)
        XCTAssertNil(all.range(of: #"(?m)^\d+$"#, options: .regularExpression), "page numbers dropped")
        XCTAssertTrue(imported.sections[0].text.hasPrefix("First Chapter"))
        XCTAssertTrue(imported.sections[1].text.hasPrefix("Second Chapter.\n\nInland the fields"))
        XCTAssertTrue(imported.sections[0].text.contains(prose[0]), "lines reflowed into the paragraph")
    }

    func test_pdf_without_text_layer_says_so() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scan.pdf")
        try drawPDF(pages: [[]], to: url)
        XCTAssertThrowsError(try DocumentImporter.importOffMain(url, format: .pdf)) { error in
            XCTAssertEqual(error as? StudioImportError, .noTextLayer("scan.pdf"))
        }
    }
}
