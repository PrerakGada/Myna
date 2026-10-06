// AwayDecisionTests.swift — which combinations of lock / idle / frontmost
// make the user "away", and the microphone-signal choice behind the call hold.
import CoreAudio
import XCTest

@testable import Myna

final class AwayDecisionTests: XCTestCase {
    private let iterm = "com.googlecode.iterm2"

    private func away(
        _ signals: AwaySignals, _ policy: AwayPolicy = AwayPolicy(), host: String? = "com.googlecode.iterm2"
    ) -> AwayDecision.Reason? {
        AwayDecision.reason(signals: signals, policy: policy, hostBundleId: host)
    }

    func test_at_desk_by_default() {
        XCTAssertNil(away(AwaySignals(idleSeconds: 5, frontmostBundleId: "com.google.Chrome")))
    }

    func test_locked_or_display_asleep_is_away() {
        XCTAssertEqual(away(AwaySignals(screenLocked: true)), .screenLocked)
        XCTAssertEqual(away(AwaySignals(displayAsleep: true)), .displayAsleep)
    }

    func test_lock_signal_off_ignores_lock() {
        var policy = AwayPolicy()
        policy.whenLocked = false
        policy.whenIdle = false
        XCTAssertNil(away(AwaySignals(screenLocked: true, displayAsleep: true), policy))
    }

    func test_idle_threshold_defaults_to_two_minutes() {
        XCTAssertNil(away(AwaySignals(idleSeconds: 119)))
        XCTAssertEqual(away(AwaySignals(idleSeconds: 120)), .idle)
    }

    func test_idle_threshold_follows_setting_and_is_clamped() {
        var policy = AwayPolicy()
        policy.idleMinutes = 5
        XCTAssertNil(away(AwaySignals(idleSeconds: 299), policy))
        XCTAssertEqual(away(AwaySignals(idleSeconds: 300), policy), .idle)
        policy.idleMinutes = 0  // nonsense from defaults → clamped to 1 minute
        XCTAssertEqual(away(AwaySignals(idleSeconds: 60), policy), .idle)
        policy.idleMinutes = 999  // clamped to 30
        XCTAssertEqual(away(AwaySignals(idleSeconds: 1_800), policy), .idle)
    }

    func test_idle_signal_off_ignores_idle() {
        var policy = AwayPolicy()
        policy.whenIdle = false
        XCTAssertNil(away(AwaySignals(idleSeconds: 10_000), policy))
    }

    func test_frontmost_signal_is_off_by_default() {
        XCTAssertNil(away(AwaySignals(frontmostBundleId: "com.google.Chrome")))
    }

    func test_frontmost_signal_when_on() {
        var policy = AwayPolicy()
        policy.whenNotFrontmost = true
        XCTAssertEqual(away(AwaySignals(frontmostBundleId: "com.google.Chrome"), policy), .notFrontmost)
        XCTAssertNil(away(AwaySignals(frontmostBundleId: iterm), policy))
    }

    func test_frontmost_signal_cannot_decide_without_a_host() {
        var policy = AwayPolicy()
        policy.whenNotFrontmost = true
        XCTAssertNil(away(AwaySignals(frontmostBundleId: "com.google.Chrome"), policy, host: nil))
        XCTAssertNil(away(AwaySignals(frontmostBundleId: "com.google.Chrome"), policy, host: ""))
        XCTAssertNil(away(AwaySignals(frontmostBundleId: nil), policy))
    }

    func test_any_one_signal_is_enough() {
        var policy = AwayPolicy()
        policy.whenNotFrontmost = true
        // In front and active, but the display slept: away.
        XCTAssertEqual(away(AwaySignals(displayAsleep: true, frontmostBundleId: iterm), policy), .displayAsleep)
        // Typing in another app: away only by the frontmost signal.
        XCTAssertEqual(away(AwaySignals(idleSeconds: 1, frontmostBundleId: "com.apple.Safari"), policy), .notFrontmost)
    }

    func test_all_signals_off_is_never_away() {
        let policy = AwayPolicy(whenLocked: false, whenIdle: false, whenNotFrontmost: false)
        XCTAssertFalse(AwayDecision.isAway(
            signals: AwaySignals(screenLocked: true, displayAsleep: true, idleSeconds: 99_999,
                                 frontmostBundleId: "x"),
            policy: policy, hostBundleId: iterm))
    }

    // MARK: microphone

    func test_separate_input_device_uses_the_device_flag() {
        XCTAssertTrue(MicrophoneUse.decide(
            inputDevice: 10, outputDevice: 20, deviceRunning: { true }, otherProcessRecording: { false }))
        XCTAssertFalse(MicrophoneUse.decide(
            inputDevice: 10, outputDevice: 20, deviceRunning: { false }, otherProcessRecording: { true }))
    }

    func test_headset_that_is_input_and_output_uses_the_process_check() {
        // Myna's own speech makes a combined device "running"; that must not hold it.
        XCTAssertFalse(MicrophoneUse.decide(
            inputDevice: 10, outputDevice: 10, deviceRunning: { true }, otherProcessRecording: { false }))
        XCTAssertTrue(MicrophoneUse.decide(
            inputDevice: 10, outputDevice: 10, deviceRunning: { false }, otherProcessRecording: { true }))
        // Too old a macOS to ask per process: don't hold.
        XCTAssertFalse(MicrophoneUse.decide(
            inputDevice: 10, outputDevice: 10, deviceRunning: { true }, otherProcessRecording: { nil }))
    }

    func test_no_input_device_never_holds() {
        XCTAssertFalse(MicrophoneUse.decide(
            inputDevice: nil, outputDevice: 20, deviceRunning: { true }, otherProcessRecording: { true }))
    }
}
