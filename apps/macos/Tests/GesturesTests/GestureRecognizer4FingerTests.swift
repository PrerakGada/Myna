// GestureRecognizer4FingerTests.swift — drives the pure-Swift state
// machine with synthetic touch + pressure events to verify each
// gesture classification path. No private framework, no NSEvent, no
// real hardware.
import XCTest

@testable import Myna

final class GestureRecognizer4FingerTests: XCTestCase {
    // Helper: drive a single tap (touchdown to 4, then up to 0) over
    // `duration` seconds starting at `start`. Returns the timestamp of
    // the final lift frame.
    @discardableResult
    private func driveTap(
        on recognizer: GestureRecognizer4Finger,
        start: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        recognizer.onTouchFrame(.init(timestamp: start, fingerCount: 4))
        recognizer.onTouchFrame(.init(timestamp: start + duration, fingerCount: 0))
        return start + duration
    }

    // Helper: drive a single click — 4-finger contact + pressure stage
    // ≥ 2 — then release.
    @discardableResult
    private func driveClick(
        on recognizer: GestureRecognizer4Finger,
        start: TimeInterval,
        contactDuration: TimeInterval = 0.080
    ) -> TimeInterval {
        recognizer.onTouchFrame(.init(timestamp: start, fingerCount: 4))
        recognizer.onPressure(.init(timestamp: start + 0.020, stage: 2))
        recognizer.onTouchFrame(.init(timestamp: start + contactDuration, fingerCount: 0))
        return start + contactDuration
    }

    private func makeRecognizer(
        config: GestureRecognizerConfig = .init(doubleClickInterval: 0.500),
        sink: GestureSink
    ) -> GestureRecognizer4Finger {
        GestureRecognizer4Finger(config: config) { sink.record($0) }
    }

    // MARK: - tap

    func test_tap_emits_after_doubleClickInterval_elapses() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(doubleClickInterval: 0.500)
        let r = makeRecognizer(config: cfg, sink: sink)

        let lift = driveTap(on: r, start: 100.000, duration: 0.080)

        // Immediately after lift the recognizer is *pending*, not fired.
        XCTAssertEqual(sink.gestures, [], "tap should be held pending until double-window elapses")
        XCTAssertNotNil(r.pendingDeadline())

        // Tick past the double-click window — single tap fires.
        r.flushIfDue(at: lift + cfg.doubleClickInterval + 0.001)
        XCTAssertEqual(sink.gestures, [.tap])
    }

    func test_tap_held_too_long_is_not_emitted() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(tapMaxDuration: 0.200, doubleClickInterval: 0.500)
        let r = makeRecognizer(config: cfg, sink: sink)

        // 400 ms contact — too long to count as a tap.
        let lift = driveTap(on: r, start: 100.000, duration: 0.400)
        r.flushIfDue(at: lift + 1.0)
        XCTAssertEqual(sink.gestures, [])
    }

    func test_tap_with_fewer_than_four_fingers_is_ignored() {
        let sink = GestureSink()
        let r = makeRecognizer(sink: sink)

        r.onTouchFrame(.init(timestamp: 100.000, fingerCount: 3))
        r.onTouchFrame(.init(timestamp: 100.080, fingerCount: 0))
        r.flushIfDue(at: 101.0)
        XCTAssertEqual(sink.gestures, [])
    }

    // MARK: - double-tap

    func test_double_tap_emits_when_two_taps_within_window() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(
            tapMaxDuration: 0.220,
            doubleClickInterval: 0.500,
            postEmitDebounce: 0.050
        )
        let r = makeRecognizer(config: cfg, sink: sink)

        driveTap(on: r, start: 100.000, duration: 0.060)
        // 2nd tap 250 ms later, within double-click window.
        driveTap(on: r, start: 100.250, duration: 0.060)

        // Double-tap fires immediately on the second lift — no need to
        // wait for the window to elapse.
        XCTAssertEqual(sink.gestures, [.doubleTap])

        // And there's no lingering pending single-tap.
        r.flushIfDue(at: 101.0)
        XCTAssertEqual(sink.gestures, [.doubleTap])
    }

    func test_two_taps_outside_window_emit_two_singles() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(doubleClickInterval: 0.300)
        let r = makeRecognizer(config: cfg, sink: sink)

        driveTap(on: r, start: 100.000, duration: 0.060)
        // Wait past the double-click window so first tap commits.
        r.flushIfDue(at: 100.500)
        XCTAssertEqual(sink.gestures, [.tap])

        driveTap(on: r, start: 100.800, duration: 0.060)
        r.flushIfDue(at: 101.500)
        XCTAssertEqual(sink.gestures, [.tap, .tap])
    }

    // MARK: - click

    func test_click_emits_after_pressure_stage_2_with_four_fingers() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(doubleClickInterval: 0.500)
        let r = makeRecognizer(config: cfg, sink: sink)

        let lift = driveClick(on: r, start: 100.000)

        // Pending; single click commits after window elapses.
        XCTAssertEqual(sink.gestures, [])
        r.flushIfDue(at: lift + cfg.doubleClickInterval + 0.001)
        XCTAssertEqual(sink.gestures, [.click])
    }

    func test_pressure_without_four_finger_contact_is_ignored() {
        let sink = GestureSink()
        let r = makeRecognizer(sink: sink)

        // No prior touch frame — pressure landing on idle state.
        r.onPressure(.init(timestamp: 100.000, stage: 2))
        r.flushIfDue(at: 102.0)
        XCTAssertEqual(sink.gestures, [], "click without 4-finger contact should not fire")
    }

    func test_low_pressure_stage_does_not_count_as_click() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(doubleClickInterval: 0.300, clickStage: 2)
        let r = makeRecognizer(config: cfg, sink: sink)

        r.onTouchFrame(.init(timestamp: 100.000, fingerCount: 4))
        r.onPressure(.init(timestamp: 100.020, stage: 1))  // light click, not deep
        r.onTouchFrame(.init(timestamp: 100.060, fingerCount: 0))
        r.flushIfDue(at: 101.0)
        // The lift could in theory count as a tap because no click
        // stage was reached. That's fine — the user did tap softly.
        XCTAssertEqual(sink.gestures, [.tap])
    }

    // MARK: - double-click

    func test_double_click_emits_when_two_clicks_within_window() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(
            doubleClickInterval: 0.500,
            postEmitDebounce: 0.050
        )
        let r = makeRecognizer(config: cfg, sink: sink)

        driveClick(on: r, start: 100.000)
        driveClick(on: r, start: 100.300)

        XCTAssertEqual(sink.gestures, [.doubleClick])
        r.flushIfDue(at: 101.0)
        XCTAssertEqual(sink.gestures, [.doubleClick])
    }

    func test_two_clicks_outside_window_emit_two_singles() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(doubleClickInterval: 0.300)
        let r = makeRecognizer(config: cfg, sink: sink)

        driveClick(on: r, start: 100.000)
        r.flushIfDue(at: 100.500)
        XCTAssertEqual(sink.gestures, [.click])

        driveClick(on: r, start: 100.800)
        r.flushIfDue(at: 101.500)
        XCTAssertEqual(sink.gestures, [.click, .click])
    }

    // MARK: - debounce / postEmitDebounce

    func test_post_emit_debounce_drops_phantom_tap_immediately_after_click() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(
            doubleClickInterval: 0.300,
            postEmitDebounce: 0.200
        )
        let r = makeRecognizer(config: cfg, sink: sink)

        // Click commits after window elapses.
        driveClick(on: r, start: 100.000)
        r.flushIfDue(at: 100.500)
        XCTAssertEqual(sink.gestures, [.click])

        // 50 ms later (inside debounce) the user re-rests fingers
        // briefly. Should NOT register as a tap.
        driveTap(on: r, start: 100.550, duration: 0.060)
        r.flushIfDue(at: 101.500)
        XCTAssertEqual(sink.gestures, [.click], "phantom tap inside debounce window must be dropped")
    }

    // MARK: - cross-kind interaction

    func test_pending_tap_followed_by_click_flushes_tap_then_pends_click() {
        let sink = GestureSink()
        let cfg = GestureRecognizerConfig(
            doubleClickInterval: 0.500,
            postEmitDebounce: 0.050
        )
        let r = makeRecognizer(config: cfg, sink: sink)

        // Single tap, pending.
        driveTap(on: r, start: 100.000, duration: 0.060)
        XCTAssertEqual(sink.gestures, [])

        // 200 ms later — within tap's double window — a click arrives.
        // Tap should be promoted to fired (different kind), click pends.
        r.onTouchFrame(.init(timestamp: 100.260, fingerCount: 4))
        r.onPressure(.init(timestamp: 100.280, stage: 2))
        XCTAssertEqual(sink.gestures, [.tap])

        // Click commits after its own window.
        r.onTouchFrame(.init(timestamp: 100.340, fingerCount: 0))
        r.flushIfDue(at: 100.900)
        XCTAssertEqual(sink.gestures, [.tap, .click])
    }
}

/// Test-only sink that records all emitted gestures in order.
final class GestureSink {
    private(set) var gestures: [FourFingerGesture] = []
    func record(_ g: FourFingerGesture) { gestures.append(g) }
}
