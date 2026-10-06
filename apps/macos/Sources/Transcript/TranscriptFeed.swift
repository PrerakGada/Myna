// TranscriptFeed.swift — the two calls AppDispatcher makes as audio reaches
// the player, kept here so the dispatcher's synth loop only grows a line at
// each enqueue.
//
// Call these right after `AudioPlayer.enqueue(buffer:)` / `enqueueAll(_:)`,
// with the same buffers in the same order: the transcript's chunk indices
// must be the player's for a sentence seek to land in the right buffer.
import AVFoundation
import Foundation

extension TranscriptStore {
    /// One chunk just enqueued in the player.
    func didEnqueue(readID: UUID, chunk: SynthesizedChunk, buffer: AVAudioPCMBuffer) {
        didEnqueue(readID: readID, chunks: [chunk], buffers: [buffer])
    }

    /// Several chunks just enqueued together (the seamless lead).
    func didEnqueue(readID: UUID, chunks: [SynthesizedChunk], buffers: [AVAudioPCMBuffer]) {
        let entries = zip(chunks, buffers).map { chunk, buffer in
            // QueuedChunk computes duration exactly as the player's queue does.
            TranscriptChunk(
                text: chunk.spokenText,
                duration: QueuedChunk(index: 0, buffer: buffer).duration,
                previewOnly: chunk.fullText == nil)
        }
        didEnqueue(readID: readID, chunks: entries)
    }
}
