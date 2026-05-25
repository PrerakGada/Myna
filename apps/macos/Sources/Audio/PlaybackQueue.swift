// PlaybackQueue.swift — pure data structure managing the list of
// buffered chunks and the virtual timeline that spans them.
//
// Each chunk is one WAV-decoded PCM buffer. Total duration = sum of
// per-chunk durations. A "global position" is the elapsed seconds since
// the start of chunk 0, ignoring playback rate. Given a global position
// we can resolve which chunk it falls inside and the offset within that
// chunk's local timeline.
//
// Pure value-type-ish struct; AudioPlayer wraps it under @MainActor.
import AVFoundation
import Foundation

public struct QueuedChunk: @unchecked Sendable {
    public let index: Int
    public let buffer: AVAudioPCMBuffer
    /// Seconds. Sample count divided by buffer.format.sampleRate.
    public let duration: TimeInterval

    public init(index: Int, buffer: AVAudioPCMBuffer) {
        self.index = index
        self.buffer = buffer
        let frames = TimeInterval(buffer.frameLength)
        let rate = buffer.format.sampleRate
        self.duration = rate > 0 ? frames / rate : 0
    }
}

/// Location of a global position within a specific chunk.
public struct ChunkPosition: Sendable, Equatable {
    public let chunkIndex: Int
    public let offsetInChunk: TimeInterval

    public init(chunkIndex: Int, offsetInChunk: TimeInterval) {
        self.chunkIndex = chunkIndex
        self.offsetInChunk = offsetInChunk
    }
}

public struct PlaybackQueue: @unchecked Sendable {
    public private(set) var chunks: [QueuedChunk] = []

    public init() {}

    public var isEmpty: Bool { chunks.isEmpty }

    public mutating func append(_ chunk: QueuedChunk) {
        chunks.append(chunk)
    }

    public mutating func removeAll() {
        chunks.removeAll(keepingCapacity: false)
    }

    /// Sum of all chunk durations (independent of playback rate).
    public var totalDuration: TimeInterval {
        chunks.reduce(0) { $0 + $1.duration }
    }

    /// Given a global position (in seconds since start of chunk 0),
    /// return which chunk contains it and the offset within that
    /// chunk's local timeline. Out-of-range positions are clamped.
    public func locate(globalPosition: TimeInterval) -> ChunkPosition? {
        guard !chunks.isEmpty else { return nil }
        if globalPosition <= 0 {
            return ChunkPosition(chunkIndex: 0, offsetInChunk: 0)
        }
        var remaining = globalPosition
        for (idx, chunk) in chunks.enumerated() {
            if remaining < chunk.duration {
                return ChunkPosition(chunkIndex: idx, offsetInChunk: remaining)
            }
            remaining -= chunk.duration
        }
        // Past the end: clamp to the last chunk's end.
        let last = chunks.count - 1
        return ChunkPosition(chunkIndex: last, offsetInChunk: chunks[last].duration)
    }

    /// Convert a (chunkIndex, offsetInChunk) pair to a global position
    /// in seconds. Returns nil if chunkIndex is out of range.
    public func globalPosition(forChunk chunkIndex: Int, offset: TimeInterval) -> TimeInterval? {
        guard chunkIndex >= 0 && chunkIndex < chunks.count else { return nil }
        let prior = chunks.prefix(chunkIndex).reduce(0) { $0 + $1.duration }
        return prior + max(0, min(offset, chunks[chunkIndex].duration))
    }
}
