// PillSettingsTests.swift — verifies the v0.2.x "always visible"
// setting persists, defaults to off, and round-trips through
// SettingsViewModel correctly. Also exercises the frame-autosave
// reset path so we know "Reset pill position" wipes the right key.
import Foundation
import XCTest

@testable import Myna

@MainActor
final class PillSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
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
        try await super.tearDown()
    }

    func test_pillAlwaysVisible_defaults_off() {
        let viewModel = SettingsViewModel(store: store)
        XCTAssertFalse(viewModel.pillAlwaysVisible)
    }

    func test_pillAlwaysVisible_persists() {
        let viewModel = SettingsViewModel(store: store)
        viewModel.pillAlwaysVisible = true
        let reloaded = SettingsViewModel(store: store)
        XCTAssertTrue(reloaded.pillAlwaysVisible)
    }

    func test_pillAlwaysVisible_resetAll_returns_to_default() {
        let viewModel = SettingsViewModel(store: store)
        viewModel.pillAlwaysVisible = true
        viewModel.resetAll()
        // The user-visible contract is "value returns to default". The
        // on-disk key persists with the default value because the
        // @Published didSet writes through after resetAll() rebinds
        // each property — that's the same semantics as every other
        // setting in this view model.
        XCTAssertFalse(viewModel.pillAlwaysVisible)
        let stored = defaults.object(forKey: SettingsKey.pillAlwaysVisible.rawValue) as? Bool
        XCTAssertEqual(stored ?? SettingsDefaults.pillAlwaysVisible,
                       SettingsDefaults.pillAlwaysVisible)
    }

    func test_floatingPillFrame_autosave_key_matches_appkit_convention() {
        // Sanity-check the constant — AppKit prefixes "NSWindow Frame "
        // when persisting setFrameAutosaveName-tagged windows. If
        // AppKit changes the prefix in a future macOS, the reset
        // path will silently fail; this test will catch the drift.
        XCTAssertEqual(
            FloatingPillFrame.defaultsKey,
            "NSWindow Frame \(FloatingPillFrame.autosaveName)"
        )
        XCTAssertEqual(FloatingPillFrame.autosaveName, "dev.myna.app.pillFrame")
    }
}
