// SetupParsingTests.swift — the installer's side of the setup.sh protocol:
// `@@step` lines, ANSI stripping, the bundled daemon's version string, and a
// cross-check that every step the script announces has a row in the window.
import XCTest

@testable import Myna

final class SetupParsingTests: XCTestCase {

    func test_parses_a_step_with_a_note() {
        let event = SetupController.parseStep("@@step engine done Already installed")
        XCTAssertEqual(event, SetupController.StepEvent(id: .engine, status: .done, note: "Already installed"))
    }

    func test_parses_a_step_without_a_note() {
        let event = SetupController.parseStep("@@step model start")
        XCTAssertEqual(event?.status, .running)
        XCTAssertEqual(event?.note, "")
    }

    func test_keeps_spaces_inside_the_note() {
        let event = SetupController.parseStep("@@step check fail Myna's voice engine needs macOS 14 Sonoma or later.")
        XCTAssertEqual(event?.status, .failed)
        XCTAssertEqual(event?.note, "Myna's voice engine needs macOS 14 Sonoma or later.")
    }

    func test_rejects_unknown_steps_states_and_other_lines() {
        XCTAssertNil(SetupController.parseStep("@@step teleport done"))
        XCTAssertNil(SetupController.parseStep("@@step engine pending"))
        XCTAssertNil(SetupController.parseStep("@@step engine"))
        XCTAssertNil(SetupController.parseStep("==> Installing the voice engine"))
    }

    func test_strips_ansi_colour_codes() {
        XCTAssertEqual(SetupController.stripANSI("\u{1B}[1;35m==>\u{1B}[0m Ready"), "==> Ready")
    }

    func test_every_step_starts_pending() {
        let steps = SetupController.pendingSteps()
        XCTAssertEqual(steps.map(\.id), SetupController.StepID.allCases)
        XCTAssertTrue(steps.allSatisfy { $0.status == .pending })
    }

    func test_reads_the_daemon_version_line() {
        XCTAssertEqual(DaemonService.parseVersion("__version__ = \"0.5.0\"\n"), "0.5.0")
        XCTAssertNil(DaemonService.parseVersion("VERSION = 1\n"))
    }

    func test_setup_script_only_announces_steps_the_window_knows() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SetupTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
        let script = try String(contentsOf: repo.appendingPathComponent("dist/setup.sh"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "^\\s*begin ([a-z]+)", options: [.anchorsMatchLines])
        let range = NSRange(script.startIndex..., in: script)
        let announced = pattern.matches(in: script, range: range).compactMap { match -> String? in
            guard let idRange = Range(match.range(at: 1), in: script) else { return nil }
            return String(script[idRange])
        }
        XCTAssertFalse(announced.isEmpty)
        for id in announced {
            XCTAssertNotNil(SetupController.StepID(rawValue: id), "setup.sh announces '\(id)', which has no row")
        }
        XCTAssertEqual(Set(announced), Set(SetupController.StepID.allCases.map(\.rawValue)))
    }
}
