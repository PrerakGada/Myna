// PlaygroundExport.swift — getting a take out of the Playground: Save
// as…, drag to Finder or another app, copy, and show in Finder.
//
// A take is synthesized once, as WAV. Every other format is made from
// that WAV by the daemon's /v2/transcode, never by rendering again,
// because the sampled engines (Chatterbox, Pocket TTS) would say it
// differently the second time and the file would not be the take you
// chose.
import AppKit
import Foundation
import UniformTypeIdentifiers

/// How a take becomes a file in a given format.
enum PlaygroundSavePlan: Equatable, Sendable {
    /// The take already is this file: write its bytes.
    case writeWAV
    /// Re-encode the WAV through the daemon.
    case transcode(format: String)
}

enum PlaygroundExport {

    /// Always offered, even when the daemon can't be asked what else it
    /// can encode: WAV needs no encoder.
    static let wav = AudioFormatInfo(
        id: "wav", label: "WAV", available: true, ext: "wav", mime: "audio/wav", reason: nil)

    static func plan(for format: AudioFormatInfo) -> PlaygroundSavePlan {
        format.id.lowercased() == "wav" ? .writeWAV : .transcode(format: format.id)
    }

    /// The formats the Save menu lists: the daemon's, WAV first, without
    /// raw PCM (a headerless file nothing on a Mac will open).
    static func menuFormats(_ fetched: [AudioFormatInfo]) -> [AudioFormatInfo] {
        let rest = fetched.filter { format in
            let id = format.id.lowercased()
            return id != "wav" && id != "pcm"
        }
        let wavEntry = fetched.first { $0.id.lowercased() == "wav" } ?? wav
        return [wavEntry] + rest
    }

    /// The bytes to write for `format`, from the take's WAV.
    static func encode(wav: Data, as format: AudioFormatInfo, using render: RenderClient) async throws -> Data {
        switch plan(for: format) {
        case .writeWAV:
            return wav
        case .transcode(let id):
            return try await render.transcode(wav: wav, to: id)
        }
    }

    /// Reads the take, encodes it, writes `destination`. File I/O runs
    /// off the main actor: a long take is tens of megabytes.
    static func export(
        source: URL,
        as format: AudioFormatInfo,
        to destination: URL,
        using render: RenderClient
    ) async throws {
        let wav = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: source)
        }.value
        let bytes = try await encode(wav: wav, as: format, using: render)
        try await Task.detached(priority: .userInitiated) {
            try bytes.write(to: destination, options: .atomic)
        }.value
    }

    /// Asks where to save. Nil if the user cancels.
    @MainActor
    static func chooseDestination(defaultName: String, format: AudioFormatInfo) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Take"
        panel.prompt = "Save"
        panel.nameFieldStringValue = defaultName
        if let type = UTType(filenameExtension: format.ext) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - drag and copy

    /// A copy of the take's audio under a readable name, for dragging and
    /// the pasteboard: the stored file is named by its id, and a file
    /// called `t_4f0c….wav` landing on the desktop helps nobody. A hard
    /// link where the volume allows it, so nothing is duplicated.
    static func shareableFile(source: URL, takeId: String, fileName: String) -> URL? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("MynaPlayground", isDirectory: true)
            .appendingPathComponent(takeId, isDirectory: true)
        let destination = folder.appendingPathComponent(fileName)
        if fm.fileExists(atPath: destination.path) { return destination }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try fm.linkItem(at: source, to: destination)
            } catch {
                try fm.copyItem(at: source, to: destination)
            }
            return destination
        } catch {
            return nil
        }
    }

    /// What a take row hands to a drag session.
    static func dragProvider(for file: URL?) -> NSItemProvider {
        guard let file else { return NSItemProvider() }
        let provider = NSItemProvider(object: file as NSURL)
        provider.suggestedName = file.deletingPathExtension().lastPathComponent
        return provider
    }

    @MainActor
    static func copyFileToPasteboard(_ file: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
    }

    @MainActor
    static func copyTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    static func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
