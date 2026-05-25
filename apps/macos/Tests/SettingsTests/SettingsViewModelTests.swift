// SettingsViewModelTests.swift — exercises defaults, persistence,
// reset, and validation. Tests use an ephemeral UserDefaults suite so
// the developer's real preferences are untouched.
import Foundation
import XCTest

@testable import Myna

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() async throws {
        try await super.setUp()
        // Unique suite per test, wiped clean.
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

    func test_default_values_match_daemon_config() {
        let viewModel = SettingsViewModel(store: store)
        XCTAssertEqual(viewModel.voice, "af_heart")
        XCTAssertEqual(viewModel.defaultSpeed, 1.0)
        XCTAssertEqual(viewModel.summaryMode, false)
        XCTAssertEqual(viewModel.daemonURL, "http://127.0.0.1")
        XCTAssertEqual(viewModel.daemonPort, 8_766)
        XCTAssertEqual(viewModel.enginePort, 8_765)
    }

    func test_voice_persists_across_relaunch() {
        let viewModel = SettingsViewModel(store: store)
        viewModel.voice = "am_michael"
        let reloaded = SettingsViewModel(store: store)
        XCTAssertEqual(reloaded.voice, "am_michael")
    }

    func test_speed_clamps_on_set() {
        let viewModel = SettingsViewModel(store: store)
        viewModel.defaultSpeed = 5.0
        XCTAssertEqual(viewModel.defaultSpeed, 2.0)
        viewModel.defaultSpeed = -1
        XCTAssertEqual(viewModel.defaultSpeed, 0.5)
    }

    func test_reset_clears_all_user_defaults() {
        let viewModel = SettingsViewModel(store: store)
        viewModel.voice = "am_michael"
        viewModel.defaultSpeed = 1.5
        viewModel.summaryMode = true
        viewModel.daemonPort = 9_000
        viewModel.resetAll()
        XCTAssertEqual(viewModel.voice, "af_heart")
        XCTAssertEqual(viewModel.defaultSpeed, 1.0)
        XCTAssertFalse(viewModel.summaryMode)
        XCTAssertEqual(viewModel.daemonPort, 8_766)
        // And a fresh view model sees the same.
        let fresh = SettingsViewModel(store: store)
        XCTAssertEqual(fresh.voice, "af_heart")
        XCTAssertEqual(fresh.defaultSpeed, 1.0)
    }

    func test_daemon_url_validation_rejects_remote() {
        let viewModel = SettingsViewModel(store: store)
        XCTAssertNotNil(viewModel.validateDaemonURL("http://example.com"))
        XCTAssertNotNil(viewModel.validateDaemonURL("https://example.com"))
        XCTAssertNotNil(viewModel.validateDaemonURL("ftp://localhost"))
        XCTAssertNotNil(viewModel.validateDaemonURL("not a url"))
        XCTAssertNil(viewModel.validateDaemonURL("http://127.0.0.1"))
        XCTAssertNil(viewModel.validateDaemonURL("http://localhost:8766"))
        XCTAssertNil(viewModel.validateDaemonURL("http://[::1]:8766"))
    }

    func test_setDaemonURL_rejects_remote_and_records_error() {
        let viewModel = SettingsViewModel(store: store)
        XCTAssertFalse(viewModel.setDaemonURL("http://example.com"))
        XCTAssertNotNil(viewModel.daemonURLError)
        XCTAssertNotEqual(viewModel.daemonURL, "http://example.com")
        XCTAssertTrue(viewModel.setDaemonURL("http://localhost"))
        XCTAssertNil(viewModel.daemonURLError)
        XCTAssertEqual(viewModel.daemonURL, "http://localhost")
    }

    func test_fullDaemonBaseURL_combines_url_and_port() {
        let viewModel = SettingsViewModel(store: store)
        viewModel.daemonURL = "http://127.0.0.1"
        viewModel.daemonPort = 8_766
        let url = viewModel.fullDaemonBaseURL
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertEqual(url?.port, 8_766)
    }

    func test_clear_cache_handles_missing_dir() {
        let viewModel = SettingsViewModel(store: store)
        // First call may or may not find a cache dir; just assert no crash.
        _ = viewModel.clearCache()
    }
}
