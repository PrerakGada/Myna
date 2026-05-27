// IconStateTests.swift — exercises the pure state-mapping logic that
// drives the 5-state bird icon (S07). The mapping is a pure function,
// so tests pass in raw signal values and assert on the computed state.
import XCTest

@testable import Myna

final class IconStateTests: XCTestCase {
    private func compute(
        reachability: MenuBarController.DaemonReachability = .up,
        daemonState: String? = nil,
        paused: Bool = false,
        playing: Bool = false,
        engineUp: Bool? = nil,
        loading: Bool = false
    ) -> IconState {
        IconStateMapping.compute(
            reachability: reachability,
            daemonStateRaw: daemonState,
            isPlayerPaused: paused,
            isPlayerPlaying: playing,
            isEngineUp: engineUp,
            isPlayerLoading: loading
        )
    }

    func test_daemon_down_is_error() {
        XCTAssertEqual(compute(reachability: .down), .error)
        XCTAssertEqual(compute(reachability: .down, playing: true), .error)
    }

    func test_player_paused_dominates_daemon_state() {
        XCTAssertEqual(compute(daemonState: "speaking", paused: true), .paused)
    }

    func test_daemon_speaking_or_streaming_maps_to_speaking() {
        XCTAssertEqual(compute(daemonState: "speaking"), .speaking)
        XCTAssertEqual(compute(daemonState: "streaming"), .speaking)
    }

    func test_daemon_thinking_or_synthesizing_maps_to_thinking() {
        XCTAssertEqual(compute(daemonState: "thinking"), .thinking)
        XCTAssertEqual(compute(daemonState: "synthesizing"), .thinking)
    }

    func test_daemon_error_state_maps_to_error() {
        XCTAssertEqual(compute(daemonState: "error"), .error)
    }

    func test_player_playing_without_daemon_hint_maps_to_speaking() {
        XCTAssertEqual(compute(daemonState: "idle", playing: true), .speaking)
    }

    func test_no_signals_means_idle() {
        XCTAssertEqual(compute(), .idle)
    }

    func test_engine_up_false_maps_to_error_even_when_daemon_reachable() {
        XCTAssertEqual(compute(engineUp: false), .error)
        // engine_up=false dominates over any otherwise-positive daemon state
        XCTAssertEqual(compute(daemonState: "idle", engineUp: false), .error)
        XCTAssertEqual(compute(daemonState: "speaking", engineUp: false), .error)
        XCTAssertEqual(compute(daemonState: "synthesizing", engineUp: false), .error)
        XCTAssertEqual(compute(playing: true, engineUp: false), .error)
    }

    func test_engine_up_true_preserves_existing_state_mapping() {
        XCTAssertEqual(compute(daemonState: "speaking", engineUp: true), .speaking)
        XCTAssertEqual(compute(daemonState: "synthesizing", engineUp: true), .thinking)
        XCTAssertEqual(compute(daemonState: "idle", engineUp: true), .idle)
        XCTAssertEqual(compute(engineUp: true), .idle)
    }

    func test_engine_up_nil_preserves_legacy_behavior() {
        // No engine_up signal: trust reachability + daemon state as before.
        XCTAssertEqual(compute(daemonState: "speaking", engineUp: nil), .speaking)
        XCTAssertEqual(compute(engineUp: nil), .idle)
    }

    // MARK: - loading (pre-audio prelude)

    func test_loading_maps_to_thinking_when_idle() {
        XCTAssertEqual(compute(loading: true), .thinking)
    }

    func test_loading_does_not_override_playing() {
        XCTAssertEqual(compute(playing: true, loading: true), .speaking)
    }

    func test_loading_does_not_override_paused() {
        XCTAssertEqual(compute(paused: true, loading: true), .paused)
    }

    func test_loading_does_not_override_daemon_error() {
        XCTAssertEqual(compute(daemonState: "error", loading: true), .error)
    }

    func test_daemon_thinking_still_thinking_with_loading() {
        // Both signals agree → still thinking. Just confirming no
        // ordering surprise where loading short-circuits before daemon
        // signals are read.
        XCTAssertEqual(compute(daemonState: "synthesizing", loading: true), .thinking)
    }

    func test_loading_does_not_override_daemon_down() {
        XCTAssertEqual(compute(reachability: .down, loading: true), .error)
    }

    func test_isAnimated_only_speaking_and_thinking() {
        XCTAssertTrue(IconState.speaking.isAnimated)
        XCTAssertTrue(IconState.thinking.isAnimated)
        XCTAssertFalse(IconState.idle.isAnimated)
        XCTAssertFalse(IconState.paused.isAnimated)
        XCTAssertFalse(IconState.error.isAnimated)
    }
}
