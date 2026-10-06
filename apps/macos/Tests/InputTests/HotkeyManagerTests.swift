// HotkeyManagerTests.swift — verify (1) defaults exactly match v1
// keybindings.json (compatibility) and (2) the manager invokes the
// stored handler when prompted. Real global hotkey registration is
// intentionally skipped — Lane A doesn't register real OS-level
// shortcuts inside tests (would fight with whatever's running).
import KeyboardShortcuts
import XCTest

@testable import Myna

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func test_default_shortcuts_match_v1_for_compatibility() {
        // v1 defaults from hammerspoon/myna.lua DEFAULT_BINDINGS:
        //   speak_selection_full:    cmd+alt+shift+s
        //   speak_selection_summary: cmd+alt+shift+a
        //   read_chrome_article:     cmd+alt+shift+r
        //   pause_resume:            cmd+alt+shift+space
        //   stop:                    cmd+alt+shift+.
        struct Expected {
            let name: KeyboardShortcuts.Name
            let key: KeyboardShortcuts.Key
            let mods: NSEvent.ModifierFlags
        }
        let expected: [Expected] = [
            Expected(name: .speakSelectionFull, key: .s, mods: [.command, .option, .shift]),
            Expected(name: .speakSelectionSummary, key: .a, mods: [.command, .option, .shift]),
            Expected(name: .readChromeArticle, key: .r, mods: [.command, .option, .shift]),
            Expected(name: .pauseResume, key: .space, mods: [.command, .option, .shift]),
            Expected(name: .stop, key: .period, mods: [.command, .option, .shift]),
        ]
        for entry in expected {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: entry.name) else {
                XCTFail("no default for \(entry.name.rawValue)")
                continue
            }
            XCTAssertEqual(shortcut.key, entry.key, "key for \(entry.name.rawValue)")
            XCTAssertEqual(shortcut.modifiers, entry.mods, "modifiers for \(entry.name.rawValue)")
        }
    }

    func test_all_eight_actions_present() {
        // The five v1 actions, skip-to-next (read queue), and previous /
        // next sentence (transcript).
        XCTAssertEqual(HotkeyAction.allCases.count, 8)
        XCTAssertEqual(KeyboardShortcuts.Name.allMynaShortcuts.count, 8)
    }

    func test_skip_to_next_has_no_default_chord() {
        // New since v1: no chord is taken from the user's apps until they
        // record one in the Shortcuts pane.
        XCTAssertNil(KeyboardShortcuts.Name.skipToNext.defaultShortcut)
        XCTAssertEqual(HotkeyAction.skipToNext.name, .skipToNext)
    }

    func test_sentence_skip_has_no_default_chord() {
        XCTAssertNil(KeyboardShortcuts.Name.previousSentence.defaultShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.nextSentence.defaultShortcut)
        XCTAssertEqual(HotkeyAction.previousSentence.name, .previousSentence)
        XCTAssertEqual(HotkeyAction.nextSentence.name, .nextSentence)
        XCTAssertEqual(HotkeyAction.previousSentence.rawValue, "previous_sentence")
        XCTAssertEqual(HotkeyAction.nextSentence.rawValue, "next_sentence")
    }

    func test_handler_invoked_on_shortcut_press() {
        let manager = HotkeyManager()
        let invocations = SendableBox<[HotkeyAction]>([])
        manager.register(handlers: [
            .speakSelectionFull: { invocations.value += [.speakSelectionFull] },
            .stop: { invocations.value += [.stop] },
        ])
        XCTAssertTrue(manager.invokeForTesting(.speakSelectionFull))
        XCTAssertTrue(manager.invokeForTesting(.stop))
        XCTAssertEqual(invocations.value, [.speakSelectionFull, .stop])
    }

    func test_handler_unregistered_on_disable() {
        let manager = HotkeyManager()
        let invocations = SendableBox<Int>(0)
        manager.register(handlers: [
            .speakSelectionFull: { invocations.value += 1 }
        ])
        XCTAssertTrue(manager.isRegisteredForTesting)
        manager.disableAll()
        XCTAssertFalse(manager.isRegisteredForTesting)
        XCTAssertFalse(manager.invokeForTesting(.speakSelectionFull))
        XCTAssertEqual(invocations.value, 0)
    }

    func test_action_rawvalues_match_v1_strings() {
        // v1 keybindings.json keys, verbatim.
        XCTAssertEqual(HotkeyAction.speakSelectionFull.rawValue, "speak_selection_full")
        XCTAssertEqual(HotkeyAction.speakSelectionSummary.rawValue, "speak_selection_summary")
        XCTAssertEqual(HotkeyAction.readChromeArticle.rawValue, "read_chrome_article")
        XCTAssertEqual(HotkeyAction.pauseResume.rawValue, "pause_resume")
        XCTAssertEqual(HotkeyAction.stop.rawValue, "stop")
    }
}
