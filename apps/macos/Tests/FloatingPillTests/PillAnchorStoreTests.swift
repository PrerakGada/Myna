// PillAnchorStoreTests.swift — verifies the (displayID, fractional-offset)
// anchor that replaced AppKit frame autosave. The geometry is pure (NSRect
// in, NSRect out) so the strand-prevention clamp and the fractional round-
// trip are testable without real displays; an NSScreen-backed round-trip is
// guarded with XCTSkip for headless CI.
import AppKit
import XCTest

@testable import Myna

@MainActor
final class PillAnchorStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "dev.myna.app.tests.anchor.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    // MARK: - pure geometry

    func test_fractionalOffset_then_origin_roundtrips() {
        let vf = NSRect(x: 100, y: 200, width: 1000, height: 800)
        let frame = NSRect(x: 350, y: 600, width: 220, height: 36)
        let f = PillAnchorStore.fractionalOffset(of: frame, in: vf)
        XCTAssertNotNil(f)
        let o = PillAnchorStore.origin(fx: f!.x, fy: f!.y, in: vf)
        XCTAssertEqual(o.x, frame.minX, accuracy: 0.0001)
        XCTAssertEqual(o.y, frame.minY, accuracy: 0.0001)
    }

    func test_fractionalOffset_degenerate_visibleFrame_isNil() {
        let vf = NSRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertNil(PillAnchorStore.fractionalOffset(
            of: NSRect(x: 1, y: 1, width: 1, height: 1), in: vf))
    }

    func test_clamp_leaves_inbounds_frame_untouched() {
        let vf = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = NSRect(x: 400, y: 300, width: 220, height: 36)
        XCTAssertEqual(PillAnchorStore.clamp(frame, in: vf), frame)
    }

    func test_clamp_pulls_far_offscreen_frame_inside() {
        let vf = NSRect(x: 0, y: 0, width: 1000, height: 800)
        // The real strand: negative origin far outside the visible frame.
        let stranded = NSRect(x: -942, y: 1144, width: 220, height: 36)
        let c = PillAnchorStore.clamp(stranded, in: vf, margin: 8)
        XCTAssertGreaterThanOrEqual(c.minX, vf.minX + 8 - 0.0001)
        XCTAssertLessThanOrEqual(c.maxX, vf.maxX - 8 + 0.0001)
        XCTAssertGreaterThanOrEqual(c.minY, vf.minY + 8 - 0.0001)
        XCTAssertLessThanOrEqual(c.maxY, vf.maxY - 8 + 0.0001)
    }

    func test_clamp_respects_left_and_bottom_margin() {
        let vf = NSRect(x: 100, y: 100, width: 1000, height: 800)
        let frame = NSRect(x: -50, y: -50, width: 220, height: 36)
        let c = PillAnchorStore.clamp(frame, in: vf, margin: 8)
        XCTAssertEqual(c.minX, vf.minX + 8, accuracy: 0.0001)
        XCTAssertEqual(c.minY, vf.minY + 8, accuracy: 0.0001)
    }

    // MARK: - persistence

    func test_load_returns_nil_when_absent() {
        XCTAssertNil(PillAnchorStore.load(defaults: defaults))
    }

    func test_load_reads_written_keys() {
        defaults.set(true, forKey: PillAnchorStore.presentKey)
        defaults.set(7, forKey: PillAnchorStore.displayIDKey)
        defaults.set(0.25, forKey: PillAnchorStore.fxKey)
        defaults.set(0.75, forKey: PillAnchorStore.fyKey)
        let a = PillAnchorStore.load(defaults: defaults)
        XCTAssertEqual(a, PillAnchorStore.Anchor(displayID: 7, fx: 0.25, fy: 0.75))
    }

    func test_clear_removes_anchor() {
        defaults.set(true, forKey: PillAnchorStore.presentKey)
        defaults.set(7, forKey: PillAnchorStore.displayIDKey)
        PillAnchorStore.clear(defaults: defaults)
        XCTAssertNil(PillAnchorStore.load(defaults: defaults))
    }

    // MARK: - NSScreen-backed round-trip (guarded for headless CI)

    func test_save_then_restore_roundtrips_on_main_screen() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available on test host")
        }
        let vf = screen.visibleFrame
        let frame = NSRect(
            x: vf.minX + 0.3 * vf.width,
            y: vf.minY + 0.4 * vf.height,
            width: 220, height: 36
        )
        PillAnchorStore.save(frame: frame, on: screen, defaults: defaults)
        let a = try XCTUnwrap(PillAnchorStore.load(defaults: defaults))
        XCTAssertEqual(a.displayID, try XCTUnwrap(PillAnchorStore.displayID(of: screen)))
        XCTAssertEqual(a.fx, 0.3, accuracy: 0.0001)
        XCTAssertEqual(a.fy, 0.4, accuracy: 0.0001)

        // Restored at the same size lands back on the original frame
        // (already in-bounds, so the clamp is a no-op).
        let restored = PillAnchorStore.restoredFrame(
            for: a, size: frame.size, screens: NSScreen.screens, fallback: screen)
        XCTAssertEqual(restored.minX, frame.minX, accuracy: 0.5)
        XCTAssertEqual(restored.minY, frame.minY, accuracy: 0.5)
    }
}
