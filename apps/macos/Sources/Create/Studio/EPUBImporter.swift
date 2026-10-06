// EPUBImporter.swift — an EPUB into chapters, in reading order.
//
// An EPUB is a zip: META-INF/container.xml names the package (OPF) file;
// the OPF's spine lists the content files in reading order; the table of
// contents (EPUB 3 nav document, or EPUB 2 NCX) names the chapters. The
// zip is unpacked with /usr/bin/ditto, the same tool Finder uses, so no
// zip code lives in the app.
//
// Sections follow the table of contents, not the files. A spine file the
// contents point at starts a new section with that title (and a file the
// contents point into several times, the whole-book-in-one-file layout,
// is split at those anchors). A file the contents never mention continues
// the section before it — publishers split long chapters across files —
// unless it has a heading of its own. Files the book marks `linear="no"`
// and the contents page itself are kept but switched off.
import Foundation

enum EPUBImporter {
    struct SpineItem: Sendable, Equatable {
        /// Standardized absolute path, for matching table-of-contents links.
        let path: String
        let linear: Bool
        let isNavDocument: Bool
    }

    struct TOCEntry: Sendable, Equatable {
        let title: String
        let path: String
        let fragment: String?
        let depth: Int
    }

    struct Package: Sendable, Equatable {
        var title: String?
        var spine: [SpineItem]
        var toc: [TOCEntry]
    }

    /// What the off-main read produces: the package, and each spine
    /// file's text, or its raw bytes when the XML reader couldn't parse it.
    struct Contents: Sendable {
        var package: Package
        var texts: [XHTMLText?]
        var unparsed: [Int: Data]
    }

    // MARK: - reading (any thread)

    static func read(url: URL) throws -> Contents {
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("myna-studio-epub-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workDir) }
        try unzip(url, into: workDir)
        let package = try readPackage(root: workDir, name: url.lastPathComponent)

        var texts: [XHTMLText?] = []
        var unparsed: [Int: Data] = [:]
        for (index, item) in package.spine.enumerated() {
            guard let data = fileManager.contents(atPath: item.path) else {
                texts.append(nil)
                continue
            }
            if let text = XHTMLTextExtractor.extract(data) {
                texts.append(text)
            } else {
                texts.append(nil)
                unparsed[index] = data
            }
        }
        return Contents(package: package, texts: texts, unparsed: unparsed)
    }

    static func unzip(_ archive: URL, into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw StudioImportError.unreadable(archive.lastPathComponent, error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StudioImportError.brokenEPUB(archive.lastPathComponent, "it isn't a readable zip archive")
        }
    }

    static func readPackage(root: URL, name: String) throws -> Package {
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let containerData = FileManager.default.contents(atPath: containerURL.path),
              let rootfile = rootfilePath(containerXML: containerData) else {
            throw StudioImportError.brokenEPUB(name, "META-INF/container.xml is missing")
        }
        let opfURL = root.appendingPathComponent(rootfile).standardizedFileURL
        guard let opfData = FileManager.default.contents(atPath: opfURL.path),
              let opf = MiniXML.parse(opfData) else {
            throw StudioImportError.brokenEPUB(name, "its package file can't be read")
        }
        return package(opf: opf, opfURL: opfURL)
    }

    static func rootfilePath(containerXML: Data) -> String? {
        MiniXML.parse(containerXML)?.descendants("rootfile").first?.attributes["full-path"]
    }

    static func package(opf: MiniXML.Element, opfURL: URL) -> Package {
        struct ManifestItem {
            let path: String
            let mediaType: String
            let properties: String
        }
        var manifest: [String: ManifestItem] = [:]
        for item in opf.descendants("item") {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            manifest[id] = ManifestItem(
                path: resolve(href, relativeTo: opfURL).path,
                mediaType: item.attributes["media-type"] ?? "",
                properties: item.attributes["properties"] ?? ""
            )
        }
        let navPath = manifest.values.first { $0.properties.split(separator: " ").contains("nav") }?.path

        let spineElement = opf.descendants("spine").first
        var spine: [SpineItem] = []
        for ref in spineElement?.descendants("itemref") ?? [] {
            guard let idref = ref.attributes["idref"], let item = manifest[idref],
                  item.mediaType.contains("html") || item.path.hasSuffix("html") || item.path.hasSuffix(".htm")
            else { continue }
            spine.append(SpineItem(
                path: item.path,
                linear: ref.attributes["linear"]?.lowercased() != "no",
                isNavDocument: item.path == navPath
            ))
        }

        var toc: [TOCEntry] = []
        if let navPath, let data = FileManager.default.contents(atPath: navPath) {
            toc = navEntries(data, navURL: URL(fileURLWithPath: navPath))
        }
        if toc.isEmpty, let ncxId = spineElement?.attributes["toc"], let ncx = manifest[ncxId],
           let data = FileManager.default.contents(atPath: ncx.path) {
            toc = ncxEntries(data, ncxURL: URL(fileURLWithPath: ncx.path))
        }
        if toc.isEmpty, let ncx = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }),
           let data = FileManager.default.contents(atPath: ncx.path) {
            toc = ncxEntries(data, ncxURL: URL(fileURLWithPath: ncx.path))
        }

        let title = opf.descendants("title").first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Package(title: title?.isEmpty == false ? title : nil, spine: spine, toc: toc)
    }

    /// EPUB 3: the `<nav epub:type="toc">` list, flattened with depth.
    static func navEntries(_ data: Data, navURL: URL) -> [TOCEntry] {
        guard let root = MiniXML.parse(XHTMLTextExtractor.replaceNamedEntities(data)) else { return [] }
        let navs = root.descendants("nav")
        let tocNav = navs.first { nav in
            nav.attributes.contains { $0.key.hasSuffix("type") && $0.value.split(separator: " ").contains("toc") }
                || nav.attributes["role"] == "doc-toc"
        } ?? navs.first
        guard let tocNav, let list = tocNav.children.first(where: { $0.name == "ol" || $0.name == "ul" }) else {
            return []
        }
        var entries: [TOCEntry] = []
        func walk(_ list: MiniXML.Element, depth: Int) {
            for item in list.children where item.name == "li" {
                if let link = item.children.first(where: { $0.name == "a" }),
                   let href = link.attributes["href"] {
                    let title = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { entries.append(entry(title: title, href: href, base: navURL, depth: depth)) }
                }
                for sub in item.children where sub.name == "ol" || sub.name == "ul" {
                    walk(sub, depth: depth + 1)
                }
            }
        }
        walk(list, depth: 0)
        return entries
    }

    /// EPUB 2: NCX `navPoint`s, flattened with depth.
    static func ncxEntries(_ data: Data, ncxURL: URL) -> [TOCEntry] {
        guard let root = MiniXML.parse(data), let navMap = root.descendants("navmap").first else { return [] }
        var entries: [TOCEntry] = []
        func walk(_ element: MiniXML.Element, depth: Int) {
            for point in element.children where point.name == "navpoint" {
                let label = point.children.first { $0.name == "navlabel" }?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let src = point.children.first(where: { $0.name == "content" })?.attributes["src"], !label.isEmpty {
                    entries.append(entry(title: label, href: src, base: ncxURL, depth: depth))
                }
                walk(point, depth: depth + 1)
            }
        }
        walk(navMap, depth: 0)
        return entries
    }

    private static func entry(title: String, href: String, base: URL, depth: Int) -> TOCEntry {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let file = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]).removingPercentEncoding : nil
        let path = file.isEmpty ? base.standardizedFileURL.path : resolve(file, relativeTo: base).path
        let collapsed = TextCleanup.replacing(#"\s+"#, in: title, with: " ")
        return TOCEntry(title: collapsed, path: path, fragment: fragment, depth: depth)
    }

    static func resolve(_ href: String, relativeTo file: URL) -> URL {
        let decoded = href.removingPercentEncoding ?? href
        return file.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }

    // MARK: - assembly (pure)

    static func assemble(_ contents: Contents, fallbackTitle: String, origin: String) -> ImportedDocument {
        let package = contents.package
        var tocByPath: [String: [TOCEntry]] = [:]
        for entry in package.toc { tocByPath[entry.path, default: []].append(entry) }

        var sections: [ImportedSection] = []
        /// Whether the last section may absorb a following untitled file.
        var lastIsOpenChapter = false

        func append(_ title: String, _ text: String, included: Bool = true, open: Bool = true) {
            guard StudioText.wordCount(text) > 0 else { return }
            sections.append(ImportedSection(title: title, text: text, includedByDefault: included))
            lastIsOpenChapter = open && included
        }

        for (index, item) in package.spine.enumerated() {
            guard index < contents.texts.count, let content = contents.texts[index] else { continue }
            if item.isNavDocument {
                append("Contents", content.text, included: false, open: false)
                continue
            }
            if !item.linear {
                append(content.firstHeading ?? content.title ?? "Extra material", content.text,
                       included: false, open: false)
                continue
            }
            let entries = tocByPath[item.path] ?? []
            guard let minDepth = entries.map(\.depth).min() else {
                if let heading = content.firstHeading {
                    append(heading, content.text)
                } else if lastIsOpenChapter, let last = sections.indices.last {
                    sections[last].text += "\n\n" + content.text
                } else {
                    append(content.title ?? "Opening pages", content.text)
                }
                continue
            }

            // Split points: the shallowest entries into this file, by anchor offset.
            var splits: [(offset: Int, title: String)] = []
            for entry in entries where entry.depth == minDepth {
                let offset = entry.fragment.flatMap { content.anchors[$0] } ?? 0
                if !splits.contains(where: { $0.offset == offset }) { splits.append((offset, entry.title)) }
            }
            splits.sort { $0.offset < $1.offset }
            let utf8 = Array(content.text.utf8)
            func slice(_ from: Int, _ to: Int) -> String {
                let lower = min(max(0, from), utf8.count)
                let upper = min(max(lower, to), utf8.count)
                return (String(bytes: utf8[lower..<upper], encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let first = splits.first, first.offset > 0 {
                let lead = slice(0, first.offset)
                if lastIsOpenChapter, let last = sections.indices.last, StudioText.wordCount(lead) > 0 {
                    sections[last].text += "\n\n" + lead
                } else {
                    append(content.title ?? "Opening pages", lead)
                }
            }
            for (splitIndex, split) in splits.enumerated() {
                let end = splitIndex + 1 < splits.count ? splits[splitIndex + 1].offset : utf8.count
                append(split.title, slice(split.offset, end))
            }
        }

        let cleaned = sections.map {
            ImportedSection(title: $0.title, text: TextCleanup.normalize($0.text), includedByDefault: $0.includedByDefault)
        }
        return ImportedDocument(
            title: package.title ?? fallbackTitle,
            sections: cleaned,
            kind: .epub,
            origin: origin
        )
    }
}

/// Just enough XML for container.xml, the OPF, the nav document and NCX:
/// a tree of elements with lower-cased local names, attributes as written,
/// and descendant text. Chapter text never goes through this — see
/// XHTMLTextExtractor.
enum MiniXML {
    final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Element] = []
        /// All text inside this element, children included, in document order.
        fileprivate(set) var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func descendants(_ name: String) -> [Element] {
            var found: [Element] = []
            for child in children {
                if child.name == name { found.append(child) }
                found += child.descendants(name)
            }
            return found
        }
    }

    static func parse(_ data: Data) -> Element? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Element?
        private var stack: [Element] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let local = (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
            let element = Element(name: local, attributes: attributeDict)
            if let parent = stack.last {
                parent.children.append(element)
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            for element in stack { element.text += string }
        }
    }
}
