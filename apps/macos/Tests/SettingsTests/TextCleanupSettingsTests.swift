// TextCleanupSettingsTests.swift — which prep each read sends.
import Foundation
import XCTest

@testable import Myna

@MainActor
final class TextCleanupSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() async throws {
        suiteName = "dev.myna.app.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
    }

    func test_cleanup_is_on_for_every_source_by_default() {
        let settings = SettingsViewModel(store: store)
        for source in ReadSource.allCases {
            XCTAssertEqual(settings.textPrep(for: source), .auto, "\(source)")
        }
    }

    func test_main_switch_off_reads_everything_as_written() {
        let settings = SettingsViewModel(store: store)
        settings.textCleanup = false
        for source in ReadSource.allCases {
            XCTAssertEqual(settings.textPrep(for: source), .literal, "\(source)")
        }
    }

    func test_per_source_switches() {
        let settings = SettingsViewModel(store: store)
        settings.textCleanupClaudeCode = false
        XCTAssertEqual(settings.textPrep(for: .claudeCode), .literal)
        XCTAssertEqual(settings.textPrep(for: .article), .auto)

        settings.textCleanupArticles = false
        XCTAssertEqual(settings.textPrep(for: .article), .literal)

        settings.textCleanupSelection = false
        XCTAssertEqual(settings.textPrep(for: .selection), .literal)
        XCTAssertEqual(settings.textPrep(for: .clipboard), .literal)
        // Replays and Myna's own text follow only the main switch.
        XCTAssertEqual(settings.textPrep(for: .replay), .auto)
        XCTAssertEqual(settings.textPrep(for: .onboarding), .auto)
    }

    func test_switches_persist_and_reset() {
        let settings = SettingsViewModel(store: store)
        settings.textCleanup = false
        settings.textCleanupArticles = false
        let reloaded = SettingsViewModel(store: store)
        XCTAssertFalse(reloaded.textCleanup)
        XCTAssertFalse(reloaded.textCleanupArticles)
        XCTAssertTrue(reloaded.textCleanupClaudeCode)

        reloaded.resetAll()
        XCTAssertTrue(reloaded.textCleanup)
        XCTAssertTrue(reloaded.textCleanupArticles)
    }
}
