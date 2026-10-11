// PillStateTests.swift — pins every cell of the pill's layout precedence
// table so a future tweak to resolvePillLayout can't silently reorder states.
import XCTest

@testable import Myna

final class PillStateTests: XCTestCase {
    private func inputs(
        enabled: Bool = true,
        alwaysVisible: Bool = false,
        isLoading: Bool = false,
        isPlaying: Bool = false,
        isHovering: Bool = false,
        isPinned: Bool = false,
        hasPrompt: Bool = false,
        isDaemonReading: Bool = false,
        captionsOn: Bool = false,
        hasCaption: Bool = false
    ) -> PillInputs {
        PillInputs(
            enabled: enabled, alwaysVisible: alwaysVisible, isLoading: isLoading,
            isPlaying: isPlaying, isHovering: isHovering, isPinned: isPinned,
            hasPrompt: hasPrompt, isDaemonReading: isDaemonReading,
            captionsOn: captionsOn, hasCaption: hasCaption
        )
    }

    // MARK: - live captions

    func test_a_caption_opens_the_pill_while_reading() {
        XCTAssertEqual(
            resolvePillLayout(inputs(isPlaying: true, captionsOn: true, hasCaption: true)), .caption)
        // The next read loading underneath doesn't hide the sentence on screen.
        XCTAssertEqual(
            resolvePillLayout(inputs(isLoading: true, captionsOn: true, hasCaption: true)), .caption)
    }

    func test_captions_off_keeps_the_bar() {
        XCTAssertEqual(
            resolvePillLayout(inputs(isPlaying: true, captionsOn: false, hasCaption: true)), .collapsedPlaying)
    }

    func test_hover_pin_and_prompt_still_win_over_a_caption() {
        XCTAssertEqual(resolvePillLayout(inputs(isHovering: true, captionsOn: true, hasCaption: true)), .expanded)
        XCTAssertEqual(resolvePillLayout(inputs(isPinned: true, captionsOn: true, hasCaption: true)), .expanded)
        XCTAssertEqual(resolvePillLayout(inputs(hasPrompt: true, captionsOn: true, hasCaption: true)), .promptCTA)
        XCTAssertEqual(resolvePillLayout(inputs(enabled: false, captionsOn: true, hasCaption: true)), .hidden)
    }

    func test_a_daemon_read_shows_the_pill_like_the_apps_own() {
        XCTAssertEqual(resolvePillLayout(inputs(isDaemonReading: true)), .collapsedPlaying)
        XCTAssertEqual(
            resolvePillLayout(inputs(isDaemonReading: true, captionsOn: true, hasCaption: true)), .caption)
    }

    func test_disabled_is_hidden_regardless_of_everything() {
        XCTAssertEqual(
            resolvePillLayout(inputs(
                enabled: false, isPlaying: true, isPinned: true, hasPrompt: true)),
            .hidden)
    }

    func test_prompt_takes_precedence_over_play_and_pin() {
        XCTAssertEqual(
            resolvePillLayout(inputs(isPlaying: true, isPinned: true, hasPrompt: true)),
            .promptCTA)
    }

    func test_pinned_expands() {
        XCTAssertEqual(resolvePillLayout(inputs(isPinned: true)), .expanded)
    }

    func test_hovering_expands() {
        XCTAssertEqual(resolvePillLayout(inputs(isHovering: true)), .expanded)
    }

    func test_expanded_beats_processing() {
        XCTAssertEqual(resolvePillLayout(inputs(isLoading: true, isHovering: true)), .expanded)
    }

    func test_loading_is_processing() {
        XCTAssertEqual(resolvePillLayout(inputs(isLoading: true)), .processing)
    }

    func test_loading_beats_playing() {
        XCTAssertEqual(resolvePillLayout(inputs(isLoading: true, isPlaying: true)), .processing)
    }

    func test_playing_is_collapsedPlaying() {
        XCTAssertEqual(resolvePillLayout(inputs(isPlaying: true)), .collapsedPlaying)
    }

    func test_alwaysVisible_idle_is_collapsedIdle() {
        XCTAssertEqual(resolvePillLayout(inputs(alwaysVisible: true)), .collapsedIdle)
    }

    func test_idle_not_alwaysVisible_is_hidden() {
        XCTAssertEqual(resolvePillLayout(inputs()), .hidden)
    }
}
