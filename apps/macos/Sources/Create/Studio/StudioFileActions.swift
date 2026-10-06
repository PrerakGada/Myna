// StudioFileActions.swift — getting a finished file out of Myna: Finder,
// Save a copy, drag, Share (AirDrop to a phone).
//
// The daemon names files by job id (`r_7f3a9c21.m4a`). Anything that hands
// a file to the user or another app gets a copy named after the title
// instead. Copies for drag and Share live in a temporary folder and are
// APFS clones, so they cost no disk space and appear instantly even for a
// book-length file.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum StudioFileActions {
    enum ActionError: LocalizedError {
        case missing(String)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .missing(let title):
                return "The audio file for “\(title)” is missing. It may have been moved or deleted in Finder."
            case .copyFailed(let detail):
                return "Couldn't copy the file: \(detail)"
            }
        }
    }

    /// "Chapter 3 — The Long Walk.m4a". Characters Finder or other
    /// systems reject become dashes; long titles are cut at 120.
    nonisolated static func fileName(title: String, format: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0").union(.newlines).union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "Myna recording" : String(cleaned.prefix(120))
        return base + "." + format
    }

    static func fileURL(of job: RenderJob) throws -> URL {
        guard let url = job.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw ActionError.missing(job.title)
        }
        return url
    }

    /// A title-named clone in a per-job temporary folder, reused if it's
    /// already there.
    static func namedCopy(of job: RenderJob) throws -> URL {
        let source = try fileURL(of: job)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Myna Studio", isDirectory: true)
            .appendingPathComponent(job.id, isDirectory: true)
        let target = folder.appendingPathComponent(fileName(title: job.title, format: source.pathExtension))
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            throw ActionError.copyFailed(error.localizedDescription)
        }
        return target
    }

    static func reveal(_ job: RenderJob) throws {
        NSWorkspace.shared.activateFileViewerSelecting([try fileURL(of: job)])
    }

    /// Asks where, then copies. Returns false if the user cancelled.
    @discardableResult
    static func saveCopy(_ job: RenderJob) throws -> Bool {
        let source = try fileURL(of: job)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(title: job.title, format: source.pathExtension)
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        panel.message = "Save a copy of “\(job.title)”"
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                // NSSavePanel already asked the user to confirm the replace.
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ActionError.copyFailed(error.localizedDescription)
        }
        return true
    }

    static func share(_ job: RenderJob, from view: NSView) throws {
        let picker = NSSharingServicePicker(items: [try namedCopy(of: job)])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// For `.onDrag`: dropping on Finder copies the title-named file.
    static func dragProvider(for job: RenderJob) -> NSItemProvider {
        guard let url = try? namedCopy(of: job), let provider = NSItemProvider(contentsOf: url) else {
            return NSItemProvider()
        }
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        return provider
    }
}

/// Holds the NSView under a SwiftUI control, so AppKit pickers (Share)
/// can be shown attached to it.
@MainActor
final class StudioViewAnchor {
    weak var view: NSView?
}

struct StudioAnchorView: NSViewRepresentable {
    let anchor: StudioViewAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
