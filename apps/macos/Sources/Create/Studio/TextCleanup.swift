// TextCleanup.swift — the rules that make extracted text worth listening to.
//
// Two tiers. `normalize`, `joinHyphenatedLineBreaks` and `unwrap` only
// change spacing and invisible characters, so every importer runs them.
// `CleanupOptions` removes things (links, citation markers, whole short
// sections), so those are toggles in the review sheet, and each rule is
// written narrowly: a false positive deletes words the listener wanted.
//
// NSRegularExpression rather than Swift Regex: a book is ~1 MB of text,
// and Swift Regex is an order of magnitude slower on inputs that size.
import Foundation

enum TextCleanup {

    // MARK: - always on

    /// Line endings, ligatures, invisible characters and runs of spaces.
    /// Never removes a visible character.
    static func normalize(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
        out = replaceLigatures(out)
        // A soft hyphen at a line end is a word the layout split in two.
        out = replacing(#"\x{00AD}[ \t]*\n[ \t]*"#, in: out, with: "")
        out = replacing(#"[\x{00AD}\x{200B}-\x{200D}\x{2060}\x{FEFF}\x{FFFC}]"#, in: out, with: "")
        out = replacing(#"[ \t\x{00A0}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]+"#, in: out, with: " ")
        out = replacing(#" *\n *"#, in: out, with: "\n")
        out = replacing(#"\n{3,}"#, in: out, with: "\n\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Typographic ligatures read as garbage by some engines ("ﬁnd").
    static func replaceLigatures(_ text: String) -> String {
        let table: [(String, String)] = [
            ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"),
            ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"), ("\u{FB05}", "st"), ("\u{FB06}", "st"),
        ]
        guard text.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) }) else { return text }
        return table.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// "exam-\nple" → "example". Only when the next line starts in lower
    /// case, so "Jean-\nPaul" and a dash before a new sentence survive.
    static func joinHyphenatedLineBreaks(_ text: String) -> String {
        replacing(#"(\p{L})-[ \t]*\n[ \t]*(\p{Ll})"#, in: text, with: "$1$2")
    }

    /// Rejoins lines that were broken only because they hit the page or
    /// column width. A line shorter than ~60% of the typical width ended
    /// on purpose (end of a paragraph, a verse, a list item), so its break
    /// is kept. Blank lines always separate paragraphs.
    static func unwrap(_ text: String, width explicitWidth: Int? = nil) -> String {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let width = explicitWidth ?? typicalLineWidth(lines)
        guard width >= 20 else { return text }
        let joinAt = Int(Double(width) * 0.6)

        var paragraphs: [String] = []
        var current = ""
        var previousLength = 0
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
                continue
            }
            if current.isEmpty {
                current = line
            } else if previousLength >= joinAt && !startsWithListMarker(line) {
                current += " " + line
            } else {
                current += "\n" + line
            }
            previousLength = line.count
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The line length most lines reach: the 80th percentile.
    static func typicalLineWidth(_ lines: [String]) -> Int {
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        guard !lengths.isEmpty else { return 0 }
        if lengths.count < 5 { return lengths.last ?? 0 }
        return lengths[Int(Double(lengths.count - 1) * 0.8)]
    }

    /// True for text broken at a fixed column (Project Gutenberg, email,
    /// man pages). Verse and ordinary one-line-per-paragraph text fail
    /// this test, so they are never reflowed.
    static func looksHardWrapped(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 10 else { return false }
        let width = typicalLineWidth(lines)
        guard (45...100).contains(width) else { return false }
        let longest = lines.map(\.count).max() ?? 0
        guard longest <= width + 12 else { return false }
        let nearWidth = lines.filter { $0.count >= Int(Double(width) * 0.75) }.count
        return Double(nearWidth) / Double(lines.count) >= 0.55
    }

    static func startsWithListMarker(_ line: String) -> Bool {
        matches(#"^(?:[•●▪◦‣\-–*]|\(?\d{1,3}[.)]|\(?[a-z][.)])\s"#, line)
    }

    // MARK: - optional

    /// Web addresses, which no one wants read aloud letter by letter.
    /// Needs a scheme or `www.`: a bare "example.com" might be the name
    /// of the thing being discussed.
    static func removeURLs(_ text: String) -> String {
        var out = replacing(#"<?\b(?:https?://|www\.)[^\s<>"]*[^\s<>".,;:!?)\]'’”]>?"#, in: text, with: "")
        out = replacing(#"\(\s*\)|\[\s*\]"#, in: out, with: "")
        return tidyAfterRemoval(out)
    }

    /// `[12]`, `[3, 4]`, `[5–7]`, `[a]`, `[citation needed]`. Numbers only
    /// up to three digits and letters only single lower-case ones, so a
    /// bracketed word or year stays.
    static func removeCitationMarkers(_ text: String) -> String {
        let pattern = #"[ \t]?\[(?:\d{1,3}(?:\s*[,–—-]\s*\d{1,3})*|[a-z]|citation needed|clarification needed|"#
            + #"page needed|when\?|who\?|by whom\?|according to whom\?)\]"#
        return tidyAfterRemoval(replacing(pattern, in: text, with: "", options: [.caseInsensitive]))
    }

    /// Removal leaves "word ," and double spaces behind.
    private static func tidyAfterRemoval(_ text: String) -> String {
        var out = replacing(#"[ \t]+([,.;:!?])"#, in: text, with: "$1")
        out = replacing(#"[ \t]{2,}"#, in: out, with: " ")
        out = replacing(#" *\n *"#, in: out, with: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - regex helpers

    static func replacing(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func matches(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func firstMatch(_ pattern: String, in text: String, group: Int = 1,
                           options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
}

/// The review sheet's optional cleanups. Defaults depend on the source:
/// links and citation markers are everywhere in web pages and papers, and
/// almost never deliberate in pasted prose.
struct CleanupOptions: Equatable, Sendable {
    var removeURLs: Bool
    var removeCitations: Bool
    var skipShortSections: Bool

    /// Sections under this many words are "very short".
    static let shortSectionWords = 40

    static func defaults(for kind: StudioSourceKind, sectionCount: Int) -> CleanupOptions {
        CleanupOptions(
            removeURLs: true,
            removeCitations: [.web, .pdf, .epub].contains(kind),
            skipShortSections: sectionCount >= 3
        )
    }

    func apply(to text: String) -> String {
        var out = text
        if removeURLs { out = TextCleanup.removeURLs(out) }
        if removeCitations { out = TextCleanup.removeCitationMarkers(out) }
        return out
    }

    /// Tables of contents, copyright pages, indexes — the pages a book has
    /// that nobody listens to. Matched on the whole title, never a prefix,
    /// so "Contents of the Heart" is a chapter.
    static func looksLikeFrontMatter(title: String) -> Bool {
        TextCleanup.matches(
            #"^\s*(?:(?:table of )?contents|copyright(?: page)?|title page|cover|half[ -]title|index|"#
                + #"opening pages|also by .*|other (?:books|titles) by .*|about the publisher)\s*$"#,
            title,
            options: [.caseInsensitive]
        )
    }

    /// Whether "skip very short sections" should switch this one off.
    static func isSkippable(title: String, words: Int) -> Bool {
        words < shortSectionWords || looksLikeFrontMatter(title: title)
    }
}
