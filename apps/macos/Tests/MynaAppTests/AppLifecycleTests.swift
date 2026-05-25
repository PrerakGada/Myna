// AppLifecycleTests.swift — verifies the static configuration of the
// app bundle matches the spec. These are static inspections, not
// behavioural tests (which would require launching the real app).
import XCTest

final class AppLifecycleTests: XCTestCase {
    private var infoDict: [String: Any] {
        Bundle.main.infoDictionary ?? [:]
    }

    func test_app_launches_without_dock_icon() {
        let isUI = infoDict["LSUIElement"] as? Bool
        XCTAssertEqual(isUI, true, "LSUIElement must be true so Myna runs as menu-bar-only")
    }

    func test_url_scheme_registered_in_info_plist() {
        guard let types = infoDict["CFBundleURLTypes"] as? [[String: Any]] else {
            XCTFail("CFBundleURLTypes missing")
            return
        }
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertTrue(schemes.contains("myna"), "myna:// scheme not registered")
    }

    func test_min_macos_version_13_or_higher() {
        guard let versionString = infoDict["LSMinimumSystemVersion"] as? String else {
            XCTFail("LSMinimumSystemVersion missing")
            return
        }
        // Parse the first version component; require >= 13.
        let major = Int(versionString.split(separator: ".").first.map(String.init) ?? "0") ?? 0
        XCTAssertGreaterThanOrEqual(major, 13, "min macOS must be 13.0 or higher")
    }

    // The next two tests inspect the entitlements file shipped with
    // the source tree (Resources/Myna.entitlements). We don't read
    // the embedded entitlements blob at runtime because that requires
    // signing — instead we verify the source-of-truth plist.
    func test_entitlements_have_apple_events() throws {
        let plistData = try entitlementsData()
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["com.apple.security.automation.apple-events"] as? Bool, true)
    }

    func test_entitlements_have_hardened_runtime_compatible_flags() throws {
        let plistData = try entitlementsData()
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["com.apple.security.cs.allow-jit"] as? Bool, false)
        XCTAssertEqual(plist?["com.apple.security.cs.allow-unsigned-executable-memory"] as? Bool, false)
        XCTAssertEqual(plist?["com.apple.security.cs.disable-library-validation"] as? Bool, false)
        XCTAssertEqual(plist?["com.apple.security.cs.disable-executable-page-protection"] as? Bool, false)
    }

    private func entitlementsData() throws -> Data {
        // Walk up from this test file to the repo root and read the
        // entitlements file from disk.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Resources/Myna.entitlements")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            let candidate2 = dir.appendingPathComponent("apps/macos/Resources/Myna.entitlements")
            if FileManager.default.fileExists(atPath: candidate2.path) {
                return try Data(contentsOf: candidate2)
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "AppLifecycleTests", code: -1)
    }
}
