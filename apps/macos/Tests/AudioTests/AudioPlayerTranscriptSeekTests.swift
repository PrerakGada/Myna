// AudioPlayerTranscriptSeekTests.swift — AudioPlayer.seek(chunk:offset:),
// the seek-file cache, and the transcript's seek path, against real playback.
//
// An extension of AudioPlayerTests on purpose: CI skips that suite (no audio
// device on its runners) and these need one. The mixer is ducked to silence
// and the clips are short, so a local run makes no sound and takes seconds.
//
// The rapid-seek test is the one that matters most: every seek stops the
// player node, which fires the completion handlers of the buffers it drops on
// AVFAudio's own queue. On macOS 26 a main-actor closure there is a hard
// crash (macos26-mainactor-callback-trap), so this drives many of them.
import AVFoundation
import Combine
import XCTest

@testable import Myna

extension AudioPlayerTests {
    private func silentPlayer() -> (AudioPlayer, () -> Void) {
        let player = AudioPlayer()
        return (player, player.duck(to: 0))
    }

    private func wait(_ timeout: TimeInterval, until predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out after \(timeout)s")
    }

    func test_seek_to_a_chunk_start_is_exact_and_needs_no_file() async throws {
        let (player, restore) = silentPlayer()
        defer { restore(); player.stop() }
        let buffers = [0.4, 0.5, 0.6].map { SineBuffer.make(duration: $0) }
        player.enqueueAll(buffers)
        XCTAssertEqual(player.queuedChunkCount, 3)

        player.seek(chunk: 2, offset: 0)
        let chunkTwoStart = QueuedChunk(index: 0, buffer: buffers[0]).duration
            + QueuedChunk(index: 1, buffer: buffers[1]).duration
        XCTAssertEqual(player.position, chunkTwoStart, "no float drift into chunk 1")
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(player.segmentFileCount, 0, "a chunk start plays the buffer itself")

        player.seek(chunk: 7, offset: 0)
        XCTAssertEqual(player.position, chunkTwoStart, "an unknown chunk is ignored")
    }

    func test_seek_into_a_chunk_writes_one_file_and_stop_deletes_it() async throws {
        let (player, restore) = silentPlayer()
        defer { restore() }
        player.enqueueAll([SineBuffer.make(duration: 0.6), SineBuffer.make(duration: 0.6)])
        player.seek(chunk: 1, offset: 0.2)
        XCTAssertEqual(player.position, 0.8, accuracy: 0.01)
        XCTAssertEqual(player.segmentFileCount, 1)
        player.seek(chunk: 1, offset: 0.3)
        XCTAssertEqual(player.segmentFileCount, 1, "reused for the same buffer")

        player.stop()
        XCTAssertEqual(player.segmentFileCount, 0, "a later read's buffers can never hit a stale file")
    }

    func test_seek_while_paused_plays_from_the_target() async throws {
        let (player, restore) = silentPlayer()
        defer { restore(); player.stop() }
        player.enqueueAll([SineBuffer.make(duration: 0.8), SineBuffer.make(duration: 0.8)])
        player.pause()
        player.seek(chunk: 1, offset: 0)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(player.position, 0.8, accuracy: 0.01)
    }

    func test_rapid_sentence_seeks_drain_once_without_crashing() async throws {
        let (player, restore) = silentPlayer()
        defer { restore() }
        var ends: [AudioPlayer.SessionEnd] = []
        let sub = player.sessionEnds.sink { ends.append($0) }
        defer { sub.cancel() }

        player.enqueueAll((0..<3).map { _ in SineBuffer.make(duration: 0.4) })
        for step in 0..<12 {
            player.seek(chunk: step % 3, offset: step.isMultiple(of: 2) ? 0 : 0.1)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        player.seek(chunk: 2, offset: 0.3)
        try await wait(3) { player.state == .idle }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ends, [.drained], "stale completions from dropped buffers are ignored")
    }

    /// The transcript's own seek path, end to end: a click on a sentence
    /// whose audio is in the player moves the player there and lights it.
    func test_transcript_jump_seeks_the_player_when_the_audio_is_there() async throws {
        let (player, restore) = silentPlayer()
        defer { restore(); player.stop() }
        let queue = ReadQueue(performer: nil)
        let store = TranscriptStore(queue: queue)
        store.attach(player: player)

        // The queue's current read, without a performer (which would clear it).
        let read = QueuedRead(text: "irrelevant", source: .selection)
        let performer = HoldingPerformer()
        queue.performer = performer
        queue.enqueue(read)

        let buffers = [SineBuffer.make(duration: 0.6), SineBuffer.make(duration: 0.9)]
        player.enqueueAll(buffers)
        store.didEnqueue(
            readID: read.id,
            chunks: [
                TranscriptChunk(text: "First chunk.", duration: QueuedChunk(index: 0, buffer: buffers[0]).duration),
                TranscriptChunk(text: "Second one. And a third.", duration: QueuedChunk(index: 0, buffer: buffers[1]).duration),
            ])
        XCTAssertEqual(store.currentIndex, 0)

        store.jump(to: 1)
        XCTAssertEqual(player.position, 0.6, accuracy: 0.001, "chunk 1 starts where chunk 0 ends")
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(performer.performed, 1, "a seek, not a restart")

        store.nextSentence()
        XCTAssertEqual(store.currentIndex, 2)
        XCTAssertEqual(player.segmentFileCount, 1, "mid-chunk sentence")
        store.previousSentence()
        XCTAssertEqual(store.currentIndex, 1, "just began: back goes to the one before")
        XCTAssertEqual(performer.performed, 1)
    }

    /// A drained read ends Finished, not Stopped.
    func test_transcript_marks_a_read_that_played_to_the_end_finished() async throws {
        let (player, restore) = silentPlayer()
        defer { restore(); player.stop() }
        let queue = ReadQueue(performer: nil)
        let performer = HoldingPerformer()
        queue.performer = performer
        let store = TranscriptStore(queue: queue)
        store.attach(player: player)
        let read = QueuedRead(text: "irrelevant", source: .selection)
        queue.enqueue(read)
        let buffer = SineBuffer.make(duration: 0.2)
        player.enqueueAll([buffer])
        store.didEnqueue(readID: read.id, chunks: [TranscriptChunk(text: "Short.", duration: 0.2)])
        queue.synthesisDidEnd(token: queue.token, failure: nil, playerIdle: false)
        let sub = player.sessionEnds.sink { _ in queue.playbackDidDrain() }
        defer { sub.cancel() }

        try await wait(3) { store.transcript?.ending != nil }
        XCTAssertEqual(store.transcript?.ending, .finished)
    }
}

/// Keeps a read current without touching the player.
@MainActor
private final class HoldingPerformer: ReadPerformer {
    private(set) var performed = 0
    var isReading: Bool { true }
    func perform(_ read: QueuedRead, token: Int) { performed += 1 }
    func halt() {}
}
