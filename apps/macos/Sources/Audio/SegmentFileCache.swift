// SegmentFileCache.swift — the temp files AudioPlayer seeks inside.
//
// `AVAudioPlayerNode.scheduleSegment` plays part of a *file*, not a buffer,
// so a seek into the middle of a chunk writes that chunk to a temp .caf once
// and reuses the handle for later seeks into it. (A seek to a chunk's start
// uses scheduleBuffer and never comes here.)
//
// Keyed by buffer identity, which is only safe while the buffers are alive:
// after a read's buffers are freed, a new buffer can land at the same address
// and a seek would play the *old* read's audio. So the owner empties this
// whenever it empties its queue (AudioPlayer.stop(), which every read starts
// with), and the files are deleted at the same time instead of piling up in
// the temp folder. Sentence jumps made mid-chunk seeks common, which is what
// turned this from theoretical into likely.
import AVFoundation
import Foundation

@MainActor
final class SegmentFileCache {
    private var files: [ObjectIdentifier: AVAudioFile] = [:]

    var count: Int { files.count }

    /// A readable file holding `buffer`, written on first use.
    func file(for buffer: AVAudioPCMBuffer) -> AVAudioFile {
        if let cached = files[ObjectIdentifier(buffer)] {
            return cached
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-chunk-\(UUID().uuidString).caf")
        do {
            let writer = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            try writer.write(from: buffer)
            // Re-open for reading; a file opened for writing can't be used
            // with scheduleSegment.
            let readable = try AVAudioFile(forReading: url)
            files[ObjectIdentifier(buffer)] = readable
            return readable
        } catch {
            // Should be exceedingly rare; surface as a fatal so tests see it.
            fatalError("AudioPlayer: failed to materialize chunk for seeking: \(error)")
        }
    }

    /// Forget every file and delete it. Call with the buffers' queue.
    func removeAll() {
        for file in files.values {
            try? FileManager.default.removeItem(at: file.url)
        }
        files.removeAll()
    }
}
