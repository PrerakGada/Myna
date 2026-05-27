// PopoverDesignTests.swift — verify the v0.2.1 design-token constants
// stay self-consistent (no two semantically distinct colors collapse
// to the same value, options list is sorted) and that the helper
// pieces we added with the redesign (SpeedChips.options, PopoverHeader
// defaultVersion fallback) behave as expected.
//
// We can't snapshot-test SwiftUI views in CI without pulling in a
// snapshot library, so these tests exercise the pure-data surfaces of
// the new components. View-rendering bugs would still surface in
// manual smoke per the v0.2.1 acceptance criteria.
//
import SwiftUI
import XCTest

@testable import Myna

// SpeedChips.options and PopoverHeader.defaultVersion() are @MainActor-isolated
// (they live in SwiftUI view layer). Hoist the whole class onto the main actor
// so synchronous XCTestCase methods can call them without an `await` dance —
// the design-token tests below are pure-data assertions, no real concurrency.
@MainActor
final class PopoverDesignTests: XCTestCase {

    // MARK: - SpeedChips.options

    func test_speed_options_match_old_menu_set() {
        XCTAssertEqual(SpeedChips.options, [0.75, 1.0, 1.2, 1.5, 1.75, 2.0])
    }

    func test_speed_options_strictly_increasing() {
        let opts = SpeedChips.options
        for idx in 1..<opts.count {
            XCTAssertLessThan(opts[idx - 1], opts[idx], "speed options must be ascending for the chip row")
        }
    }

    func test_speed_options_cap_at_2x_rate() {
        // AVAudioUnitTimePitch.rate hard-caps at 2.0× — anything beyond
        // silently clamps. The chip row must respect that ceiling.
        XCTAssertEqual(SpeedChips.options.last, 2.0)
    }

    // MARK: - PopoverHeader.defaultVersion

    func test_default_version_falls_back_to_known_string() {
        // In a test host Bundle.main may or may not carry our Info.plist
        // (it depends on how MynaTests is hosted). Either path is fine
        // — we just want defaultVersion() to never return empty.
        let version = PopoverHeader.defaultVersion()
        XCTAssertFalse(version.isEmpty)
    }

    // MARK: - PopoverDesign color distinctness

    func test_status_dots_are_distinct() {
        // Manual smoke shouldn't rely on guessing which dot means which
        // state. They should all be visually distinct → different
        // hex hashes. We compare resolvable CGColor components via
        // a Color.description (cheap, no NSColor needed).
        let dots: [Color] = [
            PopoverDesign.dotIdle,
            PopoverDesign.dotSpeaking,
            PopoverDesign.dotThinking,
            PopoverDesign.dotPaused,
            PopoverDesign.dotError,
        ]
        let unique = Set(dots.map { "\($0)" })
        XCTAssertEqual(unique.count, dots.count, "every status dot must be distinct")
    }

    func test_popover_width_matches_brief() {
        XCTAssertEqual(PopoverDesign.popoverWidth, 360)
    }

    func test_corner_radii_match_brief() {
        XCTAssertEqual(PopoverDesign.outerCornerRadius, 12)
        XCTAssertEqual(PopoverDesign.cardCornerRadius, 8)
    }
}
