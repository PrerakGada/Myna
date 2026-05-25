// SkeletonTests.swift — sentinel tests so the test target builds before workers
// add module-specific tests. Workers are expected to add their own tests under
// AudioTests/, NetworkTests/, InputTests/, URLSchemeTests/, SettingsTests/.
import XCTest

final class SkeletonTests: XCTestCase {
    func test_skeleton_builds() {
        XCTAssertTrue(true, "Phase 0 skeleton is wired into XCTest.")
    }

    func test_app_bundle_identifier_matches_spec() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.myna.app")
    }

    func test_info_plist_declares_myna_url_scheme() {
        guard let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] else {
            XCTFail("CFBundleURLTypes missing")
            return
        }
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("myna"), "myna:// scheme not registered")
    }

    func test_info_plist_is_ui_element_no_dock_icon() {
        let isUI = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool
        XCTAssertEqual(isUI, true, "LSUIElement must be true so Myna runs as menu-bar-only")
    }
}
