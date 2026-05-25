// AudioPlayerTests.swift — real-AVAudioEngine tests with in-test
// generated sine wave buffers. Each test bounds itself to a small
// number of seconds. Total wall time well under 10s.
import AVFoundation
import Combine
import XCTest

@testable import Myna

@MainActor
final class AudioPlayerTests: XCTestCase {
    private var subscriptions: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        subscriptions.removeAll()
    }

    // MARK: enqueue + play

    func test_enqueue_single_buffer_plays_to_end() async throws {
        let player = AudioPlayer()
        let buffer = SineBuffer.make(duration: 0.3)
        player.enqueue(buffer: buffer)
        XCTAssertEqual(player.state, .playing)
        try await waitForState(player, .idle, timeout: 2.0)
        XCTAssertEqual(player.duration, 0.3, accuracy: 0.05)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.1)
    }

    // MARK: pause / resume

    func test_pause_resume_preserves_position() async throws {
        let player = AudioPlayer()
        let buffer = SineBuffer.make(duration: 1.0)
        player.enqueue(buffer: buffer)
        // Wait until 0.25–0.4s has elapsed.
        try await waitUntil(timeout: 1.5) { player.position >= 0.25 }
        player.pause()
        XCTAssertEqual(player.state, .paused)
        let paused = player.position
        XCTAssertGreaterThan(paused, 0.2)
        // While paused, position shouldn't keep moving forward (give a
        // 100ms window of tolerance for any tail callbacks).
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(player.position, paused, accuracy: 0.05)
        player.resume()
        XCTAssertEqual(player.state, .playing)
        try await waitForState(player, .idle, timeout: 2.5)
    }

    // MARK: stop clears queue

    func test_stop_clears_queue() async throws {
        let player = AudioPlayer()
        for _ in 0..<3 {
            player.enqueue(buffer: SineBuffer.make(duration: 0.5))
        }
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.position, 0, accuracy: 0.001)
        XCTAssertEqual(player.duration, 0, accuracy: 0.001)
    }

    // MARK: speed

    func test_speed_change_does_not_change_pitch() {
        let player = AudioPlayer()
        player.setSpeed(2.0)
        XCTAssertEqual(player.speed, 2.0, accuracy: 0.001)
        // Pitch should never have moved off 0.
        XCTAssertEqual(player.exposedPitch(), 0)
    }

    func test_speed_clamps_low() {
        let player = AudioPlayer()
        player.setSpeed(0.1)
        XCTAssertEqual(player.speed, 0.5, accuracy: 0.001)
    }

    func test_speed_clamps_high() {
        let player = AudioPlayer()
        player.setSpeed(10.0)
        XCTAssertEqual(player.speed, 2.0, accuracy: 0.001)
    }

    // MARK: seek

    func test_seek_within_chunk() async throws {
        let player = AudioPlayer()
        let buffer = SineBuffer.make(duration: 2.0)
        player.enqueue(buffer: buffer)
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        player.seek(to: 1.5)
        XCTAssertEqual(player.position, 1.5, accuracy: 0.1)
    }

    func test_seek_across_chunks_forward() async throws {
        let player = AudioPlayer()
        for _ in 0..<3 {
            player.enqueue(buffer: SineBuffer.make(duration: 1.0))
        }
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        player.seek(to: 2.5)
        XCTAssertEqual(player.position, 2.5, accuracy: 0.2)
    }

    func test_seek_across_chunks_backward() async throws {
        let player = AudioPlayer()
        for _ in 0..<3 {
            player.enqueue(buffer: SineBuffer.make(duration: 1.0))
        }
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        // First, jump near the end.
        player.seek(to: 2.6)
        try await Task.sleep(nanoseconds: 50_000_000)
        // Then jump back into chunk 1.
        player.seek(to: 1.2)
        XCTAssertEqual(player.position, 1.2, accuracy: 0.2)
    }

    func test_seek_clamps_at_zero() async throws {
        let player = AudioPlayer()
        let buffer = SineBuffer.make(duration: 1.0)
        player.enqueue(buffer: buffer)
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        player.seek(delta: -100)
        XCTAssertEqual(player.position, 0, accuracy: 0.1)
        XCTAssertEqual(player.state, .playing)
    }

    func test_seek_clamps_at_total_duration() async throws {
        let player = AudioPlayer()
        let buffer = SineBuffer.make(duration: 1.0)
        player.enqueue(buffer: buffer)
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        player.seek(delta: 1000)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.05)
        XCTAssertEqual(player.state, .idle)
    }

    // MARK: session replacement

    func test_session_replacement_stops_prior() async throws {
        let player = AudioPlayer()
        player.enqueue(buffer: SineBuffer.make(duration: 1.0))
        try await waitUntil(timeout: 1.0) { player.state == .playing }
        player.stop()
        XCTAssertEqual(player.state, .idle)
        player.enqueue(buffer: SineBuffer.make(duration: 0.4))
        XCTAssertEqual(player.state, .playing)
        try await waitForState(player, .idle, timeout: 2.0)
    }

    // MARK: auto-advance

    func test_buffer_callback_dequeues_next() async throws {
        let player = AudioPlayer()
        player.enqueue(buffer: SineBuffer.make(duration: 0.3))
        player.enqueue(buffer: SineBuffer.make(duration: 0.3))
        XCTAssertEqual(player.duration, 0.6, accuracy: 0.05)
        try await waitForState(player, .idle, timeout: 5.0)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.2)
    }

    // MARK: speed persists across chunks

    func test_speed_persists_across_chunks() async throws {
        let player = AudioPlayer()
        player.setSpeed(1.5)
        for _ in 0..<3 {
            player.enqueue(buffer: SineBuffer.make(duration: 0.3))
        }
        try await waitForState(player, .idle, timeout: 3.0)
        // Speed should still be 1.5 — never reset by chunk transitions.
        XCTAssertEqual(player.speed, 1.5, accuracy: 0.001)
    }

    // MARK: state publisher

    func test_state_publisher_emits_changes() async throws {
        let player = AudioPlayer()
        let states = SendableBox<[AudioPlayer.State]>([])
        let cancellable = player.$state.sink { value in
            states.value += [value]
        }
        defer { cancellable.cancel() }

        player.enqueue(buffer: SineBuffer.make(duration: 0.6))
        try await waitUntil(timeout: 1.0) { player.position >= 0.2 }
        player.pause()
        try await Task.sleep(nanoseconds: 100_000_000)
        player.resume()
        try await waitForState(player, .idle, timeout: 2.0)

        let trail = states.value
        XCTAssertTrue(trail.contains(.playing))
        XCTAssertTrue(trail.contains(.paused))
        XCTAssertTrue(trail.contains(.idle))
        // Order matters: first time we saw .playing must precede first
        // .paused, which must precede the eventual .idle.
        // swiftlint:disable:next force_unwrapping
        let firstPlaying = trail.firstIndex(of: .playing)!
        // swiftlint:disable:next force_unwrapping
        let firstPaused = trail.firstIndex(of: .paused)!
        // swiftlint:disable:next force_unwrapping
        let lastIdle = trail.lastIndex(of: .idle)!
        XCTAssertLessThan(firstPlaying, firstPaused)
        XCTAssertLessThan(firstPaused, lastIdle)
    }

    // MARK: thread safety (last-wins)

    func test_concurrent_play_is_thread_safe() async throws {
        let player = AudioPlayer()
        player.enqueue(buffer: SineBuffer.make(duration: 0.3))
        // Fire many calls in parallel — all hop to MainActor so we
        // confirm no crash and the final state is consistent.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { @MainActor in
                    player.play()
                }
            }
        }
        try await waitForState(player, .idle, timeout: 2.0)
    }

    // MARK: helpers

    private func waitForState(
        _ player: AudioPlayer,
        _ target: AudioPlayer.State,
        timeout: TimeInterval
    ) async throws {
        try await waitUntil(timeout: timeout) { player.state == target }
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: predicate) {
                return
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("waitUntil timed out after \(timeout)s")
    }
}

// MARK: - test-only accessor

extension AudioPlayer {
    /// Test hook: read the underlying TimePitch pitch value to verify
    /// it never drifts off zero.
    func exposedPitch() -> Float {
        // The private `timePitch` field exposes its underlying unit.
        timePitchPitch
    }

    private var timePitchPitch: Float {
        // Use Mirror as a last-resort reflection escape hatch since the
        // `timePitch` property is private. Cheaper than adding test-only
        // injection points to production.
        let mirror = Mirror(reflecting: self)
        for child in mirror.children where child.label == "timePitch" {
            if let unit = child.value as? TimePitchUnit {
                return unit.pitch
            }
        }
        return -1
    }
}
