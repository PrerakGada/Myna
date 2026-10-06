// XHTMLTextExtractor.swift — an EPUB chapter's XHTML to listenable text.
//
// EPUB chapters are XHTML, which is XML, so XMLParser reads them on any
// thread in a few milliseconds each. That matters for a 60-chapter book:
// the NSAttributedString HTML reader is WebKit, main-thread only and far
// slower, so it is kept as the fallback for files that aren't well formed
// (see DocumentImporter).
//
// Streaming rather than a DOM gives two things the HTML reader can't:
//   • the offset of every element `id`, so a book stored as one big file
//     can still be split at the anchors its table of contents points to;
//   • control over what is heard: footnote markers, page-break markers
//     (`epub:type="pagebreak"`, which hold page numbers), ruby glosses,
//     scripts and inline MathML are skipped, and headings get a full stop
//     so they don't run into the first sentence.
import Foundation

struct XHTMLText: Sendable, Equatable {
    var text: String
    /// Element id → UTF-8 offset into `text`.
    var anchors: [String: Int]
    var firstHeading: String?
    var title: String?
}

enum XHTMLTextExtractor {
    static func extract(_ data: Data) -> XHTMLText? {
        let parser = XMLParser(data: replaceNamedEntities(data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = XHTMLCollector()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result()
    }

    /// XHTML without its DTD doesn't define `&nbsp;` and friends, and
    /// XMLParser stops at the first undefined entity. Rewrite the common
    /// ones as numeric references first.
    static func replaceNamedEntities(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8), text.contains("&") else { return data }
        guard let regex = try? NSRegularExpression(pattern: #"&([A-Za-z][A-Za-z0-9]{1,8});"#) else { return data }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return data }
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text),
                  let code = htmlEntities[String(text[nameRange])] else { continue }
            text.replaceSubrange(whole, with: "&#\(code);")
        }
        return Data(text.utf8)
    }

    static let htmlEntities: [String: Int] = [
        "nbsp": 160, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "shy": 173, "zwj": 8205, "zwnj": 8204,
        "mdash": 8212, "ndash": 8211, "hellip": 8230, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218,
        "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "laquo": 171, "raquo": 187, "lsaquo": 8249,
        "rsaquo": 8250, "bull": 8226, "middot": 183, "copy": 169, "reg": 174, "trade": 8482, "deg": 176,
        "times": 215, "divide": 247, "prime": 8242, "Prime": 8243, "dagger": 8224, "Dagger": 8225,
        "sect": 167, "para": 182, "euro": 8364, "pound": 163, "yen": 165, "cent": 162, "frac12": 189,
        "frac14": 188, "frac34": 190, "iexcl": 161, "iquest": 191, "aacute": 225, "agrave": 224,
        "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230, "ccedil": 231,
        "eacute": 233, "egrave": 232, "ecirc": 234, "euml": 235, "iacute": 237, "igrave": 236,
        "icirc": 238, "iuml": 239, "ntilde": 241, "oacute": 243, "ograve": 242, "ocirc": 244,
        "otilde": 245, "ouml": 246, "oslash": 248, "uacute": 250, "ugrave": 249, "ucirc": 251,
        "uuml": 252, "yacute": 253, "yuml": 255, "szlig": 223, "Aacute": 193, "Agrave": 192,
        "Eacute": 201, "Egrave": 200, "Ccedil": 199, "Ntilde": 209, "Ouml": 214, "Uuml": 220,
        "Auml": 196, "oelig": 339, "OElig": 338, "minus": 8722,
    ]
}

/// Collects text as the parser streams. One instance per document, used
/// on one thread.
private final class XHTMLCollector: NSObject, XMLParserDelegate {
    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "li",
        "ul", "ol", "dl", "dt", "dd", "figure", "figcaption", "pre", "table", "tr", "header",
        "footer", "hr", "main", "address", "caption", "body",
    ]
    private static let skippedElements: Set<String> = [
        "head", "script", "style", "rt", "rp", "nav", "svg", "math", "template", "object",
        "audio", "video", "iframe", "noscript", "button", "select", "textarea",
    ]
    private static let headingElements: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    private var out = ""
    private var anchors: [String: Int] = [:]
    private var firstHeading: String?
    private var title: String?
    private var titleBuffer: String?

    /// Depth inside skipped elements. Everything within is ignored.
    private var skipDepth = 0
    private var headingStarts: [Int] = []
    private var supStarts: [Int] = []

    func result() -> XHTMLText {
        XHTMLText(
            text: out.trimmingCharacters(in: .whitespacesAndNewlines),
            anchors: anchors,
            firstHeading: firstHeading,
            title: title
        )
    }

    private func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    /// Footnotes, note references and page-break markers are marked with
    /// `epub:type` (EPUB 3) or ARIA `role`.
    private func isSkippedByRole(_ attributes: [String: String]) -> Bool {
        let semantics = [attributes["epub:type"], attributes["role"]]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !semantics.isEmpty else { return false }
        return ["pagebreak", "noteref", "footnote", "endnote", "rearnote", "doc-note", "doc-backlink", "annoref"]
            .contains { semantics.contains($0) }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        if name == "title" && skipDepth > 0 && title == nil { titleBuffer = "" }
        if skipDepth > 0 || Self.skippedElements.contains(name) || isSkippedByRole(attributeDict) {
            skipDepth += 1
            return
        }
        if Self.blockElements.contains(name) { breakParagraph() }
        if name == "br" { breakLine() }
        if name == "td" || name == "th" { appendSpace() }
        if let id = attributeDict["id"] ?? attributeDict["xml:id"] { anchors[id] = out.utf8.count }
        if Self.headingElements.contains(name) { headingStarts.append(out.utf8.count) }
        if name == "sup" { supStarts.append(out.utf8.count) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        if name == "title", let buffer = titleBuffer {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? nil : trimmed
            titleBuffer = nil
        }
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }
        if name == "sup", let start = supStarts.popLast() {
            // A superscript that is only digits or marks is a note marker.
            let added = suffix(from: start)
            if TextCleanup.matches(#"^[\s\d*†‡§¶,]+$"#, added) { truncate(to: start) }
        }
        if Self.headingElements.contains(name), let start = headingStarts.popLast() {
            let heading = suffix(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty {
                if firstHeading == nil { firstHeading = heading }
                trimTrailingSpaces()
                if let last = out.last, !".!?:;…".contains(last) { out += "." }
            }
        }
        if Self.blockElements.contains(name) { breakParagraph() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if titleBuffer != nil { titleBuffer? += string }
        guard skipDepth == 0 else { return }
        // Called thousands of times per chapter, so no regex here.
        var atBreak = out.isEmpty || out.hasSuffix("\n") || out.hasSuffix(" ")
        for scalar in string.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !atBreak { out.unicodeScalars.append(" ") }
                atBreak = true
            } else {
                out.unicodeScalars.append(scalar)
                atBreak = false
            }
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            self.parser(parser, foundCharacters: string)
        }
    }

    // MARK: - output helpers

    private func breakParagraph() {
        trimTrailingSpaces()
        guard !out.isEmpty else { return }
        if out.hasSuffix("\n\n") { return }
        out += out.hasSuffix("\n") ? "\n" : "\n\n"
    }

    private func breakLine() {
        trimTrailingSpaces()
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
    }

    private func appendSpace() {
        if !out.isEmpty && !out.hasSuffix(" ") && !out.hasSuffix("\n") { out += " " }
    }

    private func trimTrailingSpaces() {
        while out.hasSuffix(" ") { out.removeLast() }
    }

    private func suffix(from utf8Offset: Int) -> String {
        let utf8 = out.utf8
        guard utf8Offset <= utf8.count else { return "" }
        let index = utf8.index(utf8.startIndex, offsetBy: utf8Offset)
        return String(out[index...])
    }

    private func truncate(to utf8Offset: Int) {
        let utf8 = out.utf8
        guard utf8Offset <= utf8.count else { return }
        out = String(out[..<utf8.index(utf8.startIndex, offsetBy: utf8Offset)])
    }
}
