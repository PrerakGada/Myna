// DocumentImporter.swift — one entry point for every way text gets into
// Studio: files, pasted text, a web page.
//
// Which reader runs where: plain text, Markdown, rich text, PDF and the
// EPUB unpack all run off the main thread, because a book can take a
// second or two. Only the two uses of AppKit's HTML reader (an .html file,
// and an EPUB chapter too malformed for the XML reader) come back to the
// main actor, because that reader is WebKit.
//
// Several files at once become one document, one or more sections per
// file, in Finder's name order ("Chapter 2" before "Chapter 10"). That
// suits a folder of chapters; unrelated articles can be switched off in
// the review sheet or dropped one at a time.
import Foundation
import UniformTypeIdentifiers

enum StudioImportError: LocalizedError, Equatable {
    case unsupported(String)
    case unreadable(String, String?)
    case locked(String)
    case noTextLayer(String)
    case brokenEPUB(String, String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "Studio can't read \(name). It reads text, Markdown, RTF, Word, OpenDocument, HTML, PDF and EPUB files."
        case .unreadable(let name, let detail):
            return "Couldn't open \(name)" + (detail.map { ": \($0)" } ?? ".")
        case .locked(let name):
            return "\(name) is password-protected. Open it in Preview, unlock it, export a copy, and add that instead."
        case .noTextLayer(let name):
            return "\(name) has no text in it, only images of pages (a scan). It needs text recognition (OCR) first."
        case .brokenEPUB(let name, let detail):
            return "\(name) doesn't look like a valid EPUB: \(detail)."
        case .empty(let name):
            return "There's no readable text in \(name)."
        }
    }
}

enum DocumentImporter {
    enum Format: Sendable, Equatable {
        case plain, markdown, richText, html, pdf, epub
    }

    static let extensions: [String: Format] = [
        "txt": .plain, "text": .plain,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
        "rtf": .richText, "rtfd": .richText, "docx": .richText, "doc": .richText, "odt": .richText,
        "html": .html, "htm": .html, "xhtml": .html,
        "pdf": .pdf,
        "epub": .epub,
    ]

    static func format(for url: URL) -> Format? {
        extensions[url.pathExtension.lowercased()]
    }

    /// For the open panel.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.plainText, .rtf, .rtfd, .html, .pdf, .epub]
        types += ["md", "markdown", "docx", "doc", "odt", "xhtml"].compactMap { UTType(filenameExtension: $0) }
        return types
    }

    // MARK: - files

    @MainActor
    static func importFiles(_ urls: [URL]) async throws -> ImportedDocument {
        let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = ordered.first else { throw StudioImportError.empty("the selection") }
        if ordered.count == 1 { return try await importFile(first) }

        var documents: [ImportedDocument] = []
        for url in ordered { documents.append(try await importFile(url)) }
        var sections: [ImportedSection] = []
        for document in documents {
            if document.sections.count == 1, var only = document.sections.first {
                only.title = document.title
                sections.append(only)
            } else {
                sections += document.sections
            }
        }
        let kinds = Set(documents.map(\.kind))
        return ImportedDocument(
            title: documents[0].title,
            sections: sections,
            kind: kinds.count == 1 ? documents[0].kind : .richText,
            origin: "\(ordered.count) files"
        )
    }

    @MainActor
    static func importFile(_ url: URL) async throws -> ImportedDocument {
        guard let format = format(for: url) else { throw StudioImportError.unsupported(url.lastPathComponent) }
        let document: ImportedDocument
        switch format {
        case .html:
            document = try AttributedTextImporter.importHTML(url: url)
        case .epub:
            var contents = try await Task.detached(priority: .userInitiated) {
                try EPUBImporter.read(url: url)
            }.value
            for (index, data) in contents.unparsed {
                if let text = AttributedTextImporter.htmlPlainText(data) {
                    contents.texts[index] = XHTMLText(text: text, anchors: [:], firstHeading: nil, title: nil)
                }
            }
            document = EPUBImporter.assemble(
                contents, fallbackTitle: StudioText.titleFromFileName(url), origin: url.lastPathComponent)
        case .plain, .markdown, .richText, .pdf:
            document = try await Task.detached(priority: .userInitiated) {
                try importOffMain(url, format: format)
            }.value
        }
        guard document.wordCount > 0 else { throw StudioImportError.empty(url.lastPathComponent) }
        return document
    }

    /// Everything but HTML. Safe on any thread.
    static func importOffMain(_ url: URL, format: Format) throws -> ImportedDocument {
        switch format {
        case .plain:
            return PlainTextImporter.parse(
                try readText(url),
                fallbackTitle: StudioText.titleFromFileName(url),
                kind: .plainText,
                origin: url.lastPathComponent
            )
        case .markdown:
            return MarkdownImporter.parse(
                try readText(url), fallbackTitle: StudioText.titleFromFileName(url), origin: url.lastPathComponent)
        case .richText:
            return try AttributedTextImporter.importDocument(url: url)
        case .pdf:
            return try PDFImporter.importDocument(url: url)
        case .html, .epub:
            throw StudioImportError.unsupported(url.lastPathComponent)
        }
    }

    /// UTF-8 or whatever the file's BOM says, then Windows Latin-1, which
    /// decodes any byte sequence (old .txt files are often cp1252).
    static func readText(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StudioImportError.unreadable(url.lastPathComponent, error.localizedDescription)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let latin = String(data: data, encoding: .windowsCP1252) { return latin }
        return String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - pasted text and web pages

    static func pastedText(_ text: String) -> ImportedDocument {
        PlainTextImporter.parse(text, fallbackTitle: "Pasted text", kind: .pasted, origin: "Pasted text")
    }

    /// A web page the daemon has already extracted. One section: its
    /// structure is gone by the time the extractor hands it over.
    static func webPage(title: String?, text: String, url: String) -> ImportedDocument {
        let host = URL(string: url)?.host ?? url
        let body = TextCleanup.normalize(text)
        let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (heading?.isEmpty == false ? heading : nil) ?? StudioText.titleFromText(body) ?? host
        return ImportedDocument(
            title: name,
            sections: body.isEmpty ? [] : [ImportedSection(title: name, text: body)],
            kind: .web,
            origin: host
        )
    }
}
