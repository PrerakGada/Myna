// PlaybackQueueTests.swift — pure unit tests for the timeline math.
import AVFoundation
import XCTest

@testable import Myna

final class PlaybackQueueTests: XCTestCase {
    func test_global_position_sums_played_chunks() {
        var queue = PlaybackQueue()
        queue.append(QueuedChunk(index: 0, buffer: SineBuffer.make(duration: 2)))
        queue.append(QueuedChunk(index: 1, buffer: SineBuffer.make(duration: 3)))
        queue.append(QueuedChunk(index: 2, buffer: SineBuffer.make(duration: 4)))

        // 2.5s into chunk 2 ⇒ global = 2 + 2.5 = 4.5
        let global = queue.globalPosition(forChunk: 1, offset: 2.5)
        XCTAssertNotNil(global)
        XCTAssertEqual(global ?? -1, 4.5, accuracy: 0.01)
    }

    func test_chunk_containing_global_position_correct() {
        var queue = PlaybackQueue()
        queue.append(QueuedChunk(index: 0, buffer: SineBuffer.make(duration: 2)))
        queue.append(QueuedChunk(index: 1, buffer: SineBuffer.make(duration: 3)))
        queue.append(QueuedChunk(index: 2, buffer: SineBuffer.make(duration: 4)))

        XCTAssertEqual(queue.locate(globalPosition: 0)?.chunkIndex, 0)
        XCTAssertEqual(queue.locate(globalPosition: 1.5)?.chunkIndex, 0)
        let mid = queue.locate(globalPosition: 4.5)
        XCTAssertEqual(mid?.chunkIndex, 1)
        XCTAssertEqual(mid?.offsetInChunk ?? -1, 2.5, accuracy: 0.01)
        let inLast = queue.locate(globalPosition: 7.0)
        XCTAssertEqual(inLast?.chunkIndex, 2)
        XCTAssertEqual(inLast?.offsetInChunk ?? -1, 2.0, accuracy: 0.01)
    }

    func test_total_duration_sums_all_chunks() {
        var queue = PlaybackQueue()
        queue.append(QueuedChunk(index: 0, buffer: SineBuffer.make(duration: 1)))
        queue.append(QueuedChunk(index: 1, buffer: SineBuffer.make(duration: 2)))
        queue.append(QueuedChunk(index: 2, buffer: SineBuffer.make(duration: 3)))
        XCTAssertEqual(queue.totalDuration, 6.0, accuracy: 0.05)
    }

    func test_locate_clamps_past_end() {
        var queue = PlaybackQueue()
        queue.append(QueuedChunk(index: 0, buffer: SineBuffer.make(duration: 2)))
        let past = queue.locate(globalPosition: 100)
        XCTAssertEqual(past?.chunkIndex, 0)
        XCTAssertEqual(past?.offsetInChunk ?? -1, 2.0, accuracy: 0.05)
    }

    func test_locate_clamps_negative() {
        var queue = PlaybackQueue()
        queue.append(QueuedChunk(index: 0, buffer: SineBuffer.make(duration: 2)))
        let past = queue.locate(globalPosition: -5)
        XCTAssertEqual(past?.chunkIndex, 0)
        XCTAssertEqual(past?.offsetInChunk ?? -1, 0, accuracy: 0.001)
    }

    func test_locate_empty_returns_nil() {
        let queue = PlaybackQueue()
        XCTAssertNil(queue.locate(globalPosition: 1))
    }
}
