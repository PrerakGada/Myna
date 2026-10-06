// QuickActionTests.swift — the pure-data surfaces behind the v0.6 popover
// rework: the clipboard probe that decides whether "Read clipboard" is
// live and what it says, and the engine-down flag the popover model
// gained when the menu bar bird and the popover disagreed about health.
//
// SwiftUI rendering still isn't snapshot-tested (no snapshot library in
// CI) — these cover the logic that would otherwise only be checked by
// looking at the thing.
import XCTest

@testable import Myna

@MainActor
final class QuickActionTests: XCTestCase {

    // MARK: - ClipboardProbe.preview

    func test_preview_collapses_newlines_and_runs_of_space() {
        let messy = "Hello\n\n   world \t  again"
        XCTAssertEqual(ClipboardProbe.preview(messy), "Hello world again")
    }

    func test_preview_truncates_with_ellipsis_at_the_limit() {
        let long = String(repeating: "a", count: 200)
        let out = ClipboardProbe.preview(long, limit: 10)
        XCTAssertEqual(out, String(repeating: "a", count: 10) + "…")
    }

    func test_preview_leaves_short_text_untouched() {
        XCTAssertEqual(ClipboardProbe.preview("short", limit: 38), "short")
    }

    func test_preview_does_not_leave_a_dangling_space_before_the_ellipsis() {
        // "aaaa bbbb" cut at 5 would be "aaaa " → "aaaa …" reads as a typo.
        XCTAssertEqual(ClipboardProbe.preview("aaaa bbbb", limit: 5), "aaaa…")
    }

    // MARK: - ClipboardProbe.durationLabel

    func test_duration_label_is_seconds_for_a_sentence() {
        let sentence = "one two three four five six"
        XCTAssertTrue(
            ClipboardProbe.durationLabel(sentence).hasSuffix("s"),
            "a six-word clipboard should read in seconds, not minutes"
        )
    }

    func test_duration_label_switches_to_minutes_for_long_text() {
        // 180 wpm → 900 words is five minutes.
        let long = Array(repeating: "word", count: 900).joined(separator: " ")
        XCTAssertEqual(ClipboardProbe.durationLabel(long), "~5m")
    }

    func test_duration_label_never_claims_zero_seconds() {
        // A one-word clipboard rounds to 0s without the floor, which reads
        // as "this button does nothing".
        XCTAssertEqual(ClipboardProbe.durationLabel("hi"), "~5s")
    }

    // MARK: - PopoverModel.engineWarning

    private func build(
        reachability: MenuBarController.DaemonReachability,
        isEngineUp: Bool
    ) -> PopoverModel {
        PopoverModelBuilder.build(
            playerState: .idle,
            nowReading: nil,
            recents: [],
            ccItems: [],
            reachability: reachability,
            hotkeyLabelFor: { _ in nil },
            isEngineUp: isEngineUp
        )
    }

    func test_engine_warning_when_daemon_is_up_but_engine_is_down() {
        // The case that had no popover representation at all: the bird went
        // red via IconStateMapping while the popover said READY.
        XCTAssertTrue(build(reachability: .up, isEngineUp: false).engineWarning)
    }

    func test_no_engine_warning_when_everything_is_healthy() {
        XCTAssertFalse(build(reachability: .up, isEngineUp: true).engineWarning)
    }

    func test_unreachable_daemon_reports_an_error_not_an_engine_warning() {
        // Stacking "daemon unreachable" and "engine is down" would show the
        // user two problems when they have one.
        let model = build(reachability: .down, isEngineUp: false)
        XCTAssertFalse(model.engineWarning)
        guard case .error = model.status else {
            return XCTFail("an unreachable daemon must still own the error hero")
        }
    }

    func test_engine_warning_defaults_off_for_callers_that_do_not_know() {
        // The `isEngineUp` parameter is defaulted so older call sites (and
        // every existing test) keep compiling — make sure the default is
        // the quiet one.
        let model = PopoverModelBuilder.build(
            playerState: .idle,
            nowReading: nil,
            recents: [],
            ccItems: [],
            reachability: .up,
            hotkeyLabelFor: { _ in nil }
        )
        XCTAssertFalse(model.engineWarning)
    }
}
