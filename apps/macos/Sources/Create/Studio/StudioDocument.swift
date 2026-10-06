// StudioDocument.swift — what an import produces, before anyone reviews it.
//
// Every way into Studio (pasted text, a web page, a dropped file) ends as
// the same thing: a title plus ordered sections. A section is roughly a
// chapter; the daemon turns each one into a chapter marker in the file.
// Keeping the importers' output this small is what lets the review sheet,
// the cleanups and the request builder ignore where the text came from.
import Foundation

/// Where a document came from. Drives the defaults of the optional
/// cleanups, and nothing else.
enum StudioSourceKind: String, Sendable, Equatable {
    case pasted
    case web
    case plainText
    case markdown
    case richText
    case pdf
    case epub

    var label: String {
        switch self {
        case .pasted: return "Pasted text"
        case .web: return "Web page"
        case .plainText: return "Text file"
        case .markdown: return "Markdown"
        case .richText: return "Document"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        }
    }
}

/// One chapter-sized piece of text as the importer found it. The text
/// has had the cleanups that are always right (whitespace, PDF page
/// furniture) but none of the optional ones.
struct ImportedSection: Sendable, Equatable {
    var title: String
    var text: String
    /// False for parts a book itself marks as outside the reading order
    /// (EPUB `linear="no"`, the table-of-contents page).
    var includedByDefault: Bool

    init(title: String, text: String, includedByDefault: Bool = true) {
        self.title = title
        self.text = text
        self.includedByDefault = includedByDefault
    }
}

struct ImportedDocument: Sendable, Equatable {
    var title: String
    var sections: [ImportedSection]
    var kind: StudioSourceKind
    /// File name(s) or host, for the review sheet's "from …" line.
    var origin: String

    var wordCount: Int { sections.reduce(0) { $0 + StudioText.wordCount($1.text) } }
}

/// Headings and paragraphs, in reading order. Markdown, rich text and
/// plain text all reduce to this, and `SectionBuilder` turns it into
/// sections the same way for each of them.
enum TextBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
}

enum StudioText {
    /// Whitespace-separated words — the same measure History uses.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// A heading spoken on its own should sound like one. The daemon
    /// splits sentences on `.!?`, so an unterminated heading would run
    /// straight into the first sentence of the chapter.
    static func spokenHeading(_ heading: String) -> String {
        let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?:;…".contains(last) ? trimmed : trimmed + "."
    }

    /// First few words, for a title when the source has none.
    static func titleFromText(_ text: String, maxWords: Int = 8) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= 80 {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        }
        let words = trimmed.split(separator: " ").prefix(maxWords).joined(separator: " ")
        return words + "…"
    }

    /// File name without extension, underscores and dashes read as spaces.
    static func titleFromFileName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let spaced = base.replacingOccurrences(of: "_", with: " ")
        return spaced.isEmpty ? "Untitled" : spaced
    }
}

/// Turns a block stream into sections. The title is the one the source
/// gives (front matter, document properties, a lone top heading), else
/// `fallbackTitle` — for files, the file name.
///
/// The split level is the shallowest heading level — except when that
/// level has exactly one heading at the very top and deeper headings
/// follow it. That single heading is the document's title (a Markdown
/// file's `# Title` over `##` chapters), so the split drops a level.
enum SectionBuilder {
    static func build(
        blocks: [TextBlock],
        title explicitTitle: String?,
        fallbackTitle: String
    ) -> (title: String, sections: [ImportedSection]) {
        let headingLevels = blocks.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }
            return nil
        }
        guard let minLevel = headingLevels.min() else {
            let body = paragraphs(blocks)
            let title = explicitTitle ?? fallbackTitle
            return (title, body.isEmpty ? [] : [ImportedSection(title: title, text: body)])
        }

        var docTitle = explicitTitle
        var splitLevel = minLevel
        var working = blocks
        let topCount = headingLevels.filter { $0 == minLevel }.count
        let deeper = headingLevels.filter { $0 > minLevel }
        if topCount == 1, let firstDeeper = deeper.min(),
           let first = blocks.first, case .heading(minLevel, let text) = first {
            if docTitle == nil { docTitle = text }
            splitLevel = firstDeeper
            working.removeFirst()
        }

        var sections: [ImportedSection] = []
        var currentTitle: String?
        var current: [TextBlock] = []

        func flush() {
            let body = paragraphs(current)
            defer { current = [] }
            guard StudioText.wordCount(body) > 0 else { return }
            if let heading = currentTitle {
                // The heading is spoken, so a listener hears where a chapter starts.
                let text = StudioText.spokenHeading(heading) + "\n\n" + body
                sections.append(ImportedSection(title: heading, text: text))
            } else {
                sections.append(ImportedSection(title: docTitle ?? "Opening", text: body))
            }
        }

        for block in working {
            if case .heading(let level, let text) = block, level <= splitLevel {
                flush()
                currentTitle = text
            } else {
                current.append(block)
            }
        }
        flush()

        return (docTitle ?? fallbackTitle, sections)
    }

    /// Paragraphs joined by blank lines; sub-headings become their own
    /// spoken paragraph.
    static func paragraphs(_ blocks: [TextBlock]) -> String {
        blocks.compactMap { block -> String? in
            switch block {
            case .heading(_, let text):
                return StudioText.spokenHeading(text)
            case .paragraph(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        .joined(separator: "\n\n")
    }
}
