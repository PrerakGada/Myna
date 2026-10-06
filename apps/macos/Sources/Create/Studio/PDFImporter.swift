// PDFImporter.swift — PDFs into listenable sections.
//
// A PDF's text layer is laid-out lines, not prose. Read raw, it speaks
// the running header on every page ("THE LONG WALK · 143"), bare page
// numbers, words split by end-of-line hyphens, and a pause at every line
// break. `PDFTextCleaner` undoes that, in this order:
//
//   1. Page furniture. Lines at a page's top or bottom edge that are page
//      numbers, or that repeat (digits ignored) on three or more pages,
//      are dropped. Only edge lines are candidates, so a phrase repeated
//      in the body is never touched.
//   2. Pages are joined, hyphenated line breaks rejoined, and lines
//      reflowed into paragraphs (TextCleanup.unwrap).
//
// Sections come from the outline (bookmarks) when there is one, at page
// granularity: a chapter runs from its bookmark's page to the next one's.
// Without an outline the PDF is one section. The pure half takes page
// strings, so the rules are tested without building PDFs.
import Foundation
import PDFKit

enum PDFImporter {
    static func importDocument(url: URL) throws -> ImportedDocument {
        guard let document = PDFDocument(url: url) else {
            throw StudioImportError.unreadable(url.lastPathComponent, nil)
        }
        if document.isLocked {
            throw StudioImportError.locked(url.lastPathComponent)
        }
        let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        guard pages.contains(where: { StudioText.wordCount($0) > 0 }) else {
            throw StudioImportError.noTextLayer(url.lastPathComponent)
        }
        let title = documentTitle(document) ?? StudioText.titleFromFileName(url)
        let sections = PDFTextCleaner.sections(pages: pages, outline: outlineEntries(document), title: title)
        return ImportedDocument(title: title, sections: sections, kind: .pdf, origin: url.lastPathComponent)
    }

    /// The PDF's own title, unless it's the name of the file it was
    /// exported from ("Microsoft Word - draft3.docx").
    static func documentTitle(_ document: PDFDocument) -> String? {
        guard let raw = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !TextCleanup.matches(#"^(?:untitled|microsoft word\b|.*\.(?:docx?|pages|pdf|txt|rtf|indd|tex)$)"#,
                                   title, options: [.caseInsensitive])
        else { return nil }
        return title
    }

    /// Bookmarks as (title, page index). A single top-level bookmark that
    /// wraps everything (the book's title) is looked through.
    static func outlineEntries(_ document: PDFDocument) -> [PDFTextCleaner.OutlineEntry] {
        guard var level = document.outlineRoot else { return [] }
        while level.numberOfChildren == 1, let only = level.child(at: 0), only.numberOfChildren >= 2 {
            level = only
        }
        return (0..<level.numberOfChildren).compactMap { index in
            guard let item = level.child(at: index),
                  let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty
            else { return nil }
            let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination
            guard let page = destination?.page else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0, pageIndex < document.pageCount else { return nil }
            return PDFTextCleaner.OutlineEntry(title: label, pageIndex: pageIndex)
        }
    }
}

enum PDFTextCleaner {
    struct OutlineEntry: Equatable, Sendable {
        let title: String
        let pageIndex: Int
    }

    /// How many lines at each end of a page count as its edge.
    static let edgeLines = 2
    /// A line repeated at the edge of this many pages is a running header.
    static let repeatThreshold = 3

    static func sections(pages rawPages: [String], outline: [OutlineEntry], title: String) -> [ImportedSection] {
        let pages = stripPageFurniture(rawPages)
        let width = TextCleanup.typicalLineWidth(pages.flatMap { $0.components(separatedBy: "\n") })

        // Outline starts in page order, one per page.
        var starts: [OutlineEntry] = []
        for entry in outline.sorted(by: { $0.pageIndex < $1.pageIndex })
        where starts.last?.pageIndex != entry.pageIndex {
            starts.append(entry)
        }
        guard starts.count >= 2 else {
            let text = joinPages(pages[...], width: width)
            return StudioText.wordCount(text) > 0 ? [ImportedSection(title: title, text: text)] : []
        }

        var sections: [ImportedSection] = []
        if let first = starts.first, first.pageIndex > 0 {
            let text = joinPages(pages[0..<first.pageIndex], width: width)
            if StudioText.wordCount(text) > 0 {
                sections.append(ImportedSection(title: "Opening pages", text: text))
            }
        }
        for (index, entry) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].pageIndex : pages.count
            var text = joinPages(pages[entry.pageIndex..<end], width: width)
            guard StudioText.wordCount(text) > 0 else { continue }
            // A chapter heading can be lost to the running-header rule (the
            // chapter's name printed atop each of its pages). Say it anyway.
            if !startsWithTitle(text, entry.title) {
                text = StudioText.spokenHeading(entry.title) + "\n\n" + text
            }
            sections.append(ImportedSection(title: entry.title, text: text))
        }
        return sections
    }

    /// Joins pages into one reflowed, normalized text.
    static func joinPages(_ pages: ArraySlice<String>, width: Int) -> String {
        let joined = pages.filter { !$0.isEmpty }.joined(separator: "\n")
        let dehyphenated = TextCleanup.joinHyphenatedLineBreaks(TextCleanup.normalize(joined))
        return TextCleanup.normalize(TextCleanup.unwrap(dehyphenated, width: width))
    }

    /// Removes page numbers and running headers/footers from each page.
    static func stripPageFurniture(_ pages: [String]) -> [String] {
        let split = pages.map { page in
            page.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        var counts: [String: Int] = [:]
        if pages.count >= 4 {
            for lines in split {
                let keys = Set(edgeIndices(lines.count).map { furnitureKey(lines[$0]) })
                for key in keys where !key.isEmpty { counts[key, default: 0] += 1 }
            }
        }
        let repeated = Set(counts.filter { $0.value >= repeatThreshold }.map(\.key))

        return split.map { lines in
            let edges = edgeIndices(lines.count)
            let kept = lines.enumerated().filter { index, line in
                guard edges.contains(index) else { return true }
                if isPageNumberLine(line) { return false }
                return !repeated.contains(furnitureKey(line))
            }
            return kept.map(\.element).joined(separator: "\n")
        }
    }

    private static func edgeIndices(_ count: Int) -> Set<Int> {
        let head = 0..<min(edgeLines, count)
        let tail = max(0, count - edgeLines)..<count
        return Set(head).union(tail)
    }

    /// A header line with its page number masked, so "143 · THE LONG WALK"
    /// and "145 · THE LONG WALK" are the same line. Long lines are body text.
    static func furnitureKey(_ line: String) -> String {
        guard line.count <= 120 else { return "" }
        let masked = TextCleanup.replacing(#"\d+"#, in: line.lowercased(), with: "#")
        return TextCleanup.replacing(#"\s+"#, in: masked, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "12", "- 12 -", "Page 12", "12 of 300", "xii", "Page 3 / 10".
    static func isPageNumberLine(_ line: String) -> Bool {
        TextCleanup.matches(
            #"^[\[(\-–—]?\s*(?:page\s+)?(?:\d{1,4}|[ivxlcdm]{1,7})(?:\s*(?:of|/)\s*\d{1,4})?\s*[\])\-–—]?$"#,
            line.trimmingCharacters(in: .whitespaces),
            options: [.caseInsensitive]
        )
    }

    /// Whether the text already opens with the section's title (its first
    /// three words, compared on letters and digits, starting within the
    /// first eight words to allow for a "Chapter 3" label), so it isn't
    /// said twice.
    static func startsWithTitle(_ text: String, _ title: String) -> Bool {
        func words(_ string: String) -> [String] {
            string.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let titleWords = Array(words(title).prefix(3))
        guard !titleWords.isEmpty else { return true }
        let head = words(String(text.prefix(300)))
        guard head.count >= titleWords.count else { return false }
        return (0...(min(head.count - titleWords.count, 8))).contains { start in
            Array(head[start..<(start + titleWords.count)]) == titleWords
        }
    }
}
