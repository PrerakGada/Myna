// AudioPlayerSessionEndTests.swift — AudioPlayer.sessionEnds against real
// playback. An extension of AudioPlayerTests on purpose: CI skips that
// suite (its runners have no audio output device), and these need one.
// The mixer is ducked to silence so a local run makes no sound.
import AVFoundation
import Combine
import XCTest

@testable import Myna

extension AudioPlayerTests {
    func test_session_end_reports_drained_after_state_is_idle() async throws {
        let player = AudioPlayer()
        let restore = player.duck(to: 0)
        defer { restore() }
        var ends: [(AudioPlayer.SessionEnd, AudioPlayer.State)] = []
        let sub = player.sessionEnds.sink { [player] end in ends.append((end, player.state)) }
        defer { sub.cancel() }

        player.enqueue(buffer: SineBuffer.make(duration: 0.2))
        let deadline = Date().addingTimeInterval(3)
        while ends.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(ends.map(\.0), [.drained])
        XCTAssertEqual(ends.first?.1, .idle, "the queue reads player.state from inside the event")
    }

    func test_session_end_reports_stopped_not_drained_when_stopped_mid_clip() async throws {
        let player = AudioPlayer()
        let restore = player.duck(to: 0)
        defer { restore() }
        var ends: [AudioPlayer.SessionEnd] = []
        let sub = player.sessionEnds.sink { ends.append($0) }
        defer { sub.cancel() }

        player.enqueue(buffer: SineBuffer.make(duration: 1.0))
        try await Task.sleep(nanoseconds: 100_000_000)
        player.stop()
        // Give any stale completion callback time to (wrongly) report a drain.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ends, [.stopped])
    }

    func test_session_end_reports_drained_when_seeked_past_the_end() async throws {
        let player = AudioPlayer()
        let restore = player.duck(to: 0)
        defer { restore() }
        var ends: [AudioPlayer.SessionEnd] = []
        let sub = player.sessionEnds.sink { ends.append($0) }
        defer { sub.cancel() }

        player.enqueue(buffer: SineBuffer.make(duration: 1.0))
        player.seek(delta: 5)
        XCTAssertEqual(ends, [.drained])
        XCTAssertEqual(player.state, .idle)
    }
}
