// TextImporters.swift — plain text and Markdown into sections.
//
// Plain text has no markup, so chapters are found the way a reader finds
// them: a line on its own that says "Chapter 7" or "PART TWO". Two or more
// of those and the text splits; one alone is just a sentence. Project
// Gutenberg files are common enough to special-case: their licence header
// and footer are trimmed, and their title line names the book.
//
// Markdown is read line by line rather than through AttributedString's
// parser, which drops paragraph breaks from the plain string it returns.
// Headings split sections (see SectionBuilder); code blocks, images and
// link targets are dropped because none of them can be listened to.
import Foundation

enum PlainTextImporter {
    static func parse(_ raw: String, fallbackTitle: String, kind: StudioSourceKind, origin: String) -> ImportedDocument {
        let (body, gutenbergTitle) = trimGutenberg(raw)
        var text = TextCleanup.normalize(body)
        if TextCleanup.looksHardWrapped(text) {
            text = TextCleanup.unwrap(TextCleanup.joinHyphenatedLineBreaks(text))
        }
        // Pasted text has no file name, so its first line names it.
        let built = SectionBuilder.build(
            blocks: blocks(text),
            title: gutenbergTitle ?? (kind == .pasted ? StudioText.titleFromText(text) : nil),
            fallbackTitle: fallbackTitle
        )
        return ImportedDocument(title: built.title, sections: built.sections, kind: kind, origin: origin)
    }

    /// Paragraphs, with chapter lines promoted to headings when there are
    /// at least two of them.
    static func blocks(_ text: String) -> [TextBlock] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let chapterCount = paragraphs.filter(isChapterLine).count
        guard chapterCount >= 2 else { return paragraphs.map(TextBlock.paragraph) }

        var blocks: [TextBlock] = []
        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            if isChapterLine(paragraph) || isBookPartLine(paragraph) {
                var heading = paragraph.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                // "CHAPTER I." then "Down the Rabbit-Hole" on its own line.
                if isBareChapterLine(paragraph), index + 1 < paragraphs.count,
                   isChapterSubtitle(paragraphs[index + 1]) {
                    heading += ": " + paragraphs[index + 1]
                    index += 1
                }
                blocks.append(.heading(level: 1, text: heading))
            } else {
                blocks.append(.paragraph(paragraph))
            }
            index += 1
        }
        return blocks
    }

    private static let numberWords = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
        + "thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|"
        + "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|last|final"

    /// "Chapter 3", "CHAPTER XII. The Trial", "Part Two", "Book the First".
    /// A title after the number needs punctuation before it, or none of its
    /// own — so "Chapter one was hard to write, she said." stays prose.
    static func isChapterLine(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 80 else { return false }
        let number = #"(?:\d{1,3}|[ivxlcdm]{1,7}|the\s+\w+|(?:"# + numberWords + #")(?:[- ](?:"#
            + numberWords + #"))?)"#
        let rest = #"(?:[.:]?\s*$|[.:]\s+\S.{0,60}$|\s*[-—–]\s*\S.{0,60}$|\s+[^\s.!?,;][^.!?,;]{0,60}$)"#
        let pattern = #"^(?:chapter|part|book|act)\s+"# + number + #"\b"# + rest
        return TextCleanup.matches(pattern, paragraph, options: [.caseInsensitive])
    }

    /// "CHAPTER I." with nothing after the number.
    static func isBareChapterLine(_ paragraph: String) -> Bool {
        TextCleanup.matches(#"^(?:chapter|part|book|act)\s+[\w-]+[.:]?$"#, paragraph, options: [.caseInsensitive])
    }

    /// Prologue and friends count as chapters only in a text that already
    /// has numbered ones — on their own they are too common as words.
    static func isBookPartLine(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 40 else { return false }
        return TextCleanup.matches(
            #"^(?:prologue|epilogue|preface|foreword|afterword|introduction|interlude)[.:]?$"#,
            paragraph,
            options: [.caseInsensitive]
        )
    }

    /// A short title line with no sentence ending: "Down the Rabbit-Hole".
    static func isChapterSubtitle(_ paragraph: String) -> Bool {
        guard !paragraph.contains("\n"), paragraph.count <= 60, !isChapterLine(paragraph) else { return false }
        guard let last = paragraph.last, !".!?\"'”’…,;".contains(last) else { return false }
        return StudioText.wordCount(paragraph) <= 10
    }

    /// Keeps only the book between Project Gutenberg's START and END
    /// markers, and reads its `Title:` line.
    static func trimGutenberg(_ text: String) -> (body: String, title: String?) {
        guard let start = text.range(
            of: #"\*{3}\s*START OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return (text, nil) }
        let header = String(text[..<start.lowerBound])
        let title = TextCleanup.firstMatch(#"(?m)^Title:\s*(.+?)\s*$"#, in: header)
        var body = text[start.upperBound...]
        if let end = body.range(
            of: #"\*{3}\s*END OF (?:THE|THIS) PROJECT GUTENBERG"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            body = body[..<end.lowerBound]
        }
        return (String(body), title)
    }
}

enum MarkdownImporter {
    static func parse(_ raw: String, fallbackTitle: String, origin: String) -> ImportedDocument {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = TextCleanup.replacing(#"(?s)<!--.*?-->"#, in: text, with: "")
        let (body, frontTitle) = stripFrontMatter(text)
        let built = SectionBuilder.build(blocks: blocks(body), title: frontTitle, fallbackTitle: fallbackTitle)
        let sections = built.sections.map {
            ImportedSection(title: $0.title, text: TextCleanup.normalize($0.text), includedByDefault: $0.includedByDefault)
        }
        return ImportedDocument(title: built.title, sections: sections, kind: .markdown, origin: origin)
    }

    /// YAML front matter between `---` fences; its `title:` names the doc.
    static func stripFrontMatter(_ text: String) -> (String, String?) {
        guard text.hasPrefix("---\n"),
              let close = text.range(of: #"\n(?:---|\.\.\.)[ \t]*(?:\n|$)"#, options: .regularExpression)
        else { return (text, nil) }
        let yaml = String(text[text.index(text.startIndex, offsetBy: 4)..<close.lowerBound])
        let title = TextCleanup.firstMatch(#"(?m)^title:\s*["']?(.+?)["']?\s*$"#, in: yaml)
        return (String(text[close.upperBound...]), title)
    }

    static func blocks(_ text: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var paragraph: [String] = []
        var fence: String?

        func flush() {
            let joined = paragraph.joined(separator: " ")
            paragraph = []
            let inline = stripInline(joined)
            if !inline.isEmpty { blocks.append(.paragraph(inline)) }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = String(line.prefix(3))
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let heading = atxHeading(line) {
                flush()
                blocks.append(.heading(level: heading.level, text: stripInline(heading.text)))
                continue
            }
            // Setext: a paragraph line underlined with === or ---.
            if paragraph.count == 1, TextCleanup.matches(#"^(=+|-+)$"#, line) {
                let title = stripInline(paragraph[0])
                paragraph = []
                blocks.append(.heading(level: line.hasPrefix("=") ? 1 : 2, text: title))
                continue
            }
            if TextCleanup.matches(#"^([-*_])(\s*\1){2,}$"#, line) {
                flush()
                continue
            }
            if let note = TextCleanup.firstMatch(#"^\[\^[^\]]+\]:\s*(.*)$"#, in: line) {
                flush()
                paragraph = [note]
                flush()
                continue  // footnote definition: keep the note, drop its marker
            }
            if TextCleanup.matches(#"^\[[^\]]+\]:\s*\S"#, line) {
                continue  // link reference definition
            }
            if TextCleanup.matches(#"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, line) {
                continue  // table separator row
            }
            if line.hasPrefix("|") {
                flush()
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                paragraph = [cells.filter { !$0.isEmpty }.joined(separator: ", ")]
                flush()
                continue
            }
            var content = line
            while content.hasPrefix(">") {
                content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if let item = TextCleanup.firstMatch(#"^(?:[-*+]|\d{1,3}[.)])\s+(.*)$"#, in: content) {
                // Each list item is spoken as its own sentence.
                flush()
                let inline = stripInline(item)
                if !inline.isEmpty { blocks.append(.paragraph(StudioText.spokenHeading(inline))) }
                continue
            }
            paragraph.append(content)
        }
        flush()
        return blocks
    }

    static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        guard let hashes = TextCleanup.firstMatch(#"^(#{1,6})\s+\S"#, in: line),
              let text = TextCleanup.firstMatch(#"^#{1,6}\s+(.+?)(?:\s+#+)?\s*$"#, in: line)
        else { return nil }
        return (hashes.count, text)
    }

    /// Inline Markdown down to the words a listener should hear.
    static func stripInline(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"`+([^`]+?)`+"#, "$1"),                                   // inline code
            (#"!\[[^\]]*\]\((?:[^()]|\([^)]*\))*\)"#, ""),              // images
            (#"\[\^[^\]]+\]"#, ""),                                      // footnote refs
            (#"\[([^\]]+)\]\((?:[^()]|\([^)]*\))*\)"#, "$1"),           // links
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),                          // reference links
            (#"<((?:https?|mailto):[^>\s]+)>"#, "$1"),                   // autolinks
            (#"</?[A-Za-z][^>]*>"#, ""),                                 // inline HTML
            (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2"),                   // bold
            (#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1"),       // italic *
            (#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "$1"),         // italic _
            (#"~~(.+?)~~"#, "$1"),                                       // strikethrough
            (#"\\([\\`*_{}\[\]()#+\-.!|>~])"#, "$1"),                    // escapes
        ]
        for (pattern, template) in rules {
            out = TextCleanup.replacing(pattern, in: out, with: template)
        }
        return TextCleanup.replacing(#"\s{2,}"#, in: out, with: " ").trimmingCharacters(in: .whitespaces)
    }
}
