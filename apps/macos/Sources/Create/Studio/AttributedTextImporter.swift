// AttributedTextImporter.swift — RTF, RTFD, Word, OpenDocument and HTML.
//
// AppKit's NSAttributedString document readers do the format work. What
// they don't give back is structure: a Word file's "Heading 1" arrives as
// a paragraph in a bigger font. So headings are recovered from the
// paragraph style's `headerLevel` when a reader sets it (HTML does), and
// otherwise from type size: a short paragraph set noticeably larger than
// the body text is a heading, and its size ranks its level.
//
// Threading: the HTML reader runs WebKit and must be called on the main
// thread (Apple's documentation is explicit that it will otherwise time
// out). The other readers are safe anywhere, so books in .docx don't
// freeze the window while they load.
import AppKit
import Foundation

enum AttributedTextImporter {

    /// RTF, RTFD, DOCX, DOC, ODT. Any thread.
    static func importDocument(url: URL, kind: StudioSourceKind = .richText) throws -> ImportedDocument {
        var attributes: NSDictionary?
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(url: url, options: [:], documentAttributes: &attributes)
        } catch {
            throw StudioImportError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
        return document(from: attributed, attributes: attributes, url: url, kind: kind)
    }

    /// HTML files. Main thread only: the reader is WebKit.
    @MainActor
    static func importHTML(url: URL) throws -> ImportedDocument {
        var attributes: NSDictionary?
        let data: Data
        let attributed: NSAttributedString
        do {
            data = try Data(contentsOf: url)
            attributed = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: &attributes
            )
        } catch {
            throw StudioImportError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
        // The HTML reader doesn't report <title>; read it from the markup.
        let markup = String(bytes: data, encoding: .utf8) ?? ""
        if let title = TextCleanup.firstMatch(#"(?is)<title[^>]*>\s*(.*?)\s*</title>"#, in: markup)
            .map({ TextCleanup.replacing(#"\s+"#, in: $0, with: " ") }), !title.isEmpty {
            let fields = NSMutableDictionary(dictionary: attributes ?? [:])
            fields[NSAttributedString.DocumentAttributeKey.title] = decodeBasicEntities(title)
            attributes = fields
        }
        return document(from: attributed, attributes: attributes, url: url, kind: .richText)
    }

    private static func decodeBasicEntities(_ text: String) -> String {
        [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
         ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// Plain text of an HTML fragment, for EPUB chapters the XML reader
    /// couldn't parse. Main thread only.
    @MainActor
    static func htmlPlainText(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ) else { return nil }
        let blocks = blocks(from: attributed)
        return TextCleanup.normalize(SectionBuilder.paragraphs(blocks))
    }

    static func document(
        from attributed: NSAttributedString,
        attributes: NSDictionary?,
        url: URL,
        kind: StudioSourceKind
    ) -> ImportedDocument {
        let documentTitle = (attributes?[NSAttributedString.DocumentAttributeKey.title] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let built = SectionBuilder.build(
            blocks: blocks(from: attributed),
            title: documentTitle,
            fallbackTitle: StudioText.titleFromFileName(url)
        )
        let sections = built.sections.map { ImportedSection(title: $0.title, text: TextCleanup.normalize($0.text)) }
        return ImportedDocument(title: built.title, sections: sections, kind: kind, origin: url.lastPathComponent)
    }

    // MARK: - structure

    private struct Paragraph {
        let text: String
        let size: CGFloat
        let headerLevel: Int
    }

    static func blocks(from attributed: NSAttributedString) -> [TextBlock] {
        let paragraphs = collectParagraphs(attributed)
        guard !paragraphs.isEmpty else { return [] }

        // Body size: the size carrying the most characters.
        var weight: [CGFloat: Int] = [:]
        for paragraph in paragraphs { weight[paragraph.size.rounded(), default: 0] += paragraph.text.count }
        let bodySize = weight.max { $0.value < $1.value }?.key ?? 12

        func isHeading(_ paragraph: Paragraph) -> Bool {
            guard paragraph.text.count <= 120, StudioText.wordCount(paragraph.text) <= 20 else { return false }
            if paragraph.headerLevel > 0 { return true }
            guard let last = paragraph.text.last, !".,;".contains(last) else { return false }
            return paragraph.size.rounded() >= (bodySize * 1.2).rounded()
        }

        // Larger type ranks higher: the biggest heading size is level 1.
        let headingSizes = Set(paragraphs.filter { isHeading($0) && $0.headerLevel == 0 }.map { $0.size.rounded() })
        let sizeRank = Dictionary(
            uniqueKeysWithValues: headingSizes.sorted(by: >).enumerated().map { ($1, $0 + 1) })

        return paragraphs.map { paragraph in
            guard isHeading(paragraph) else { return .paragraph(paragraph.text) }
            let level = paragraph.headerLevel > 0 ? paragraph.headerLevel : sizeRank[paragraph.size.rounded()] ?? 1
            return .heading(level: level, text: paragraph.text)
        }
    }

    private static func collectParagraphs(_ attributed: NSAttributedString) -> [Paragraph] {
        let string = attributed.string as NSString
        var result: [Paragraph] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byParagraphs]
        ) { substring, range, _, _ in
            guard let substring else { return }
            let text = cleanParagraph(substring)
            guard !text.isEmpty else { return }
            let attrs = attributed.attributes(at: range.location, effectiveRange: nil)
            let font = attrs[.font] as? NSFont
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            result.append(Paragraph(text: text, size: font?.pointSize ?? 12, headerLevel: style?.headerLevel ?? 0))
        }
        return result
    }

    /// Readers render list bullets and table cells as tabs and glyphs.
    private static func cleanParagraph(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
        let hadBullet = TextCleanup.matches(#"^\s*[•◦▪‣⁃●○■□–-]\s"#, text)
        text = TextCleanup.replacing(#"^\s*(?:[•◦▪‣⁃●○■□–-]|\d{1,3}[.)])?\t+"#, in: text, with: "")
        text = TextCleanup.replacing(#"^\s*[•◦▪‣⁃●○■□]\s+"#, in: text, with: "")
        text = text.replacingOccurrences(of: "\t", with: " ")
        text = TextCleanup.replacing(#"\s{2,}"#, in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return hadBullet ? StudioText.spokenHeading(text) : text
    }
}
