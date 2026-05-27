// GestureRouterTests.swift — verify each `MynaGesture` case dispatches
// to the right `GestureActionTarget` method.
import XCTest

@testable import Myna

@MainActor
final class GestureRouterTests: XCTestCase {
    func test_tap_speaks_full_selection() {
        let target = FakeGestureTarget()
        let router = GestureRouter(target: target)
        router.handle(.fourFingerTap)
        XCTAssertEqual(target.calls, [.speakSelection(.full)])
    }

    func test_double_tap_stops_while_click_path_is_dormant() {
        // Provisional mapping — see GestureRouter docs. Restore
        // `.speakSelection(.summary)` once the click path is debugged
        // on real hardware.
        let target = FakeGestureTarget()
        let router = GestureRouter(target: target)
        router.handle(.fourFingerDoubleTap)
        XCTAssertEqual(target.calls, [.stop])
    }

    func test_click_toggles_pause() {
        let target = FakeGestureTarget()
        let router = GestureRouter(target: target)
        router.handle(.fourFingerClick)
        XCTAssertEqual(target.calls, [.togglePause])
    }

    func test_double_click_stops() {
        let target = FakeGestureTarget()
        let router = GestureRouter(target: target)
        router.handle(.fourFingerDoubleClick)
        XCTAssertEqual(target.calls, [.stop])
    }

    func test_router_drops_when_target_is_deallocated() {
        var target: FakeGestureTarget? = FakeGestureTarget()
        let router = GestureRouter(target: target!)
        target = nil
        // No assert needed beyond "doesn't crash" — the target is held
        // weakly so the router silently drops.
        router.handle(.fourFingerTap)
    }
}

@MainActor
final class FakeGestureTarget: GestureActionTarget {
    enum Call: Equatable {
        case speakSelection(SynthesizeMode)
        case togglePause
        case stop
        case seek(TimeInterval)
    }
    private(set) var calls: [Call] = []

    func speakSelection(mode: SynthesizeMode) { calls.append(.speakSelection(mode)) }
    func togglePause() { calls.append(.togglePause) }
    func stop() { calls.append(.stop) }
    func seek(delta: TimeInterval) { calls.append(.seek(delta)) }
}
