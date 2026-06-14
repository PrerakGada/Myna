// FloatingPillWindowTrackTests.swift — covers the tap-vs-drag
// disambiguator in FloatingPillWindow.
//
// The bug we're guarding against: prior to v0.2.x-pos-fix the
// window's mouseDown handler called `performDrag(with:)` on every
// click, then unconditionally set `hasUserPosition = true`. Effect:
//   • A bare click on the pill body locked the pill in place forever.
//   • Any cursor twitch during a click dragged the pill with the
//     cursor — Prerak's pill ended up at (-942, 1144) on his ultrawide
//     this way.
// The fix introduces a movement threshold (`FloatingPillWindow.dragThreshold`)
// before we treat the gesture as a drag, and only commits
// hasUserPosition if the origin actually shifted after performDrag.
//
// `trackDragOrTap` is the pure, testable core of that decision.
// We feed it synthetic NSEvent sequences and assert the classification.
//
// Real event-loop coverage (performDrag actually moving an NSWindow)
// would require a UI test target — out of scope here. The integration
// invariant we keep on the production path is documented in the
// mouseDown comment in FloatingPillWindow.swift.
import AppKit
import XCTest

@testable import Myna

@MainActor
final class FloatingPillWindowTrackTests: XCTestCase {

    private static let pressLocation = NSPoint(x: 100, y: 100)
    private static let threshold = FloatingPillWindow.dragThreshold

    // MARK: - factory

    /// Build a synthetic NSEvent whose `locationInWindow` is offset
    /// from `pressLocation` by (dx, dy). Used to simulate drag events
    /// for the tracking loop without spinning up a window.
    private static func makeEvent(
        type: NSEvent.EventType,
        dx: CGFloat = 0,
        dy: CGFloat = 0
    ) -> NSEvent {
        let location = NSPoint(
            x: pressLocation.x + dx,
            y: pressLocation.y + dy
        )
        // windowNumber 0 + nil context is fine for the test — we only
        // read .type and .locationInWindow inside trackDragOrTap.
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            fatalError("Failed to synthesise NSEvent of type \(type)")
        }
        return event
    }

    /// Mutable queue backing the test event stream. A class (not an
    /// inout array) because `trackDragOrTap`'s `nextEvent` parameter
    /// is an escaping closure — Swift refuses to capture an inout
    /// parameter across that boundary. Wrapping in a class gives the
    /// closure shared, mutable storage to drain on each call.
    private final class EventQueue {
        var events: [NSEvent]
        init(_ events: [NSEvent]) { self.events = events }
        /// Pop the head; return nil when exhausted.
        func next() -> NSEvent? {
            guard !events.isEmpty else { return nil }
            return events.removeFirst()
        }
    }

    // MARK: - canonical cases

    func test_bareMouseUp_isTap() {
        // The classic "I just clicked" case. No drag events at all
        // between mouseDown and mouseUp.
        let q = EventQueue([Self.makeEvent(type: .leftMouseUp)])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        XCTAssertEqual(result, .tap, "A pure mouseDown→mouseUp gesture must classify as a tap.")
    }

    func test_drag_past_threshold_returns_drag_with_initiator() {
        // Cursor moves past the threshold in one event. The returned
        // .drag must carry that event so the caller can hand it to
        // performDrag(with:) and the drag picks up at the same cursor
        // position (no jump).
        let initiator = Self.makeEvent(type: .leftMouseDragged, dx: Self.threshold + 1)
        let q = EventQueue([initiator])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        guard case .drag(let returnedEvent) = result else {
            XCTFail("Expected .drag, got \(result)")
            return
        }
        XCTAssertTrue(returnedEvent === initiator,
                      "The .drag payload must be the event that crossed the threshold (identity, not equality).")
    }

    func test_drag_exactly_at_threshold_returns_drag() {
        // Boundary: cursor moves exactly `threshold` pts. The
        // condition is >=, so this should classify as drag, not tap.
        let initiator = Self.makeEvent(type: .leftMouseDragged, dx: Self.threshold)
        let q = EventQueue([initiator])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        guard case .drag = result else {
            XCTFail("Expected .drag at exactly-threshold, got \(result)")
            return
        }
    }

    func test_drag_below_threshold_then_mouseUp_isTap() {
        // The hand-twitch case: user clicks but the cursor jitters
        // 1pt before they release. Must NOT be classified as a drag
        // (that's the bug that nudged Prerak's pill to a corner).
        let belowThreshold = Self.threshold - 1
        XCTAssertGreaterThan(belowThreshold, 0, "Sanity: threshold must be > 1 for this test to be meaningful.")
        let q = EventQueue([
            Self.makeEvent(type: .leftMouseDragged, dx: belowThreshold),
            Self.makeEvent(type: .leftMouseUp, dx: belowThreshold),
        ])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        XCTAssertEqual(result, .tap,
                       "Sub-threshold movement followed by mouseUp must classify as a tap, not a drag.")
    }

    func test_diagonal_movement_uses_euclidean_distance() {
        // Cursor moves 3pt right + 4pt down. Manhattan = 7, but
        // Euclidean = 5. The implementation uses hypot(), so a
        // diagonal twitch must respect the geometric distance.
        // With dragThreshold=4, a 3-4 diagonal (hypot=5) should drag.
        XCTAssertGreaterThan(5.0, Self.threshold, "Sanity: threshold must be < 5 for this test to assert drag.")
        let initiator = Self.makeEvent(type: .leftMouseDragged, dx: 3, dy: 4)
        let q = EventQueue([initiator])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        guard case .drag = result else {
            XCTFail("Diagonal movement of hypot=5 with threshold=\(Self.threshold) must classify as drag, got \(result)")
            return
        }
    }

    func test_accumulating_subthreshold_drags_then_pastthreshold_returns_drag() {
        // User starts moving slowly: each individual mouseDragged is
        // under-threshold, but a later one crosses it. Must NOT
        // classify the early sub-threshold events as drag (they're
        // discarded), and MUST return .drag with the *first* past-
        // threshold event as initiator. Crucially, events AFTER the
        // past-threshold one must remain in the queue — performDrag
        // is the one that consumes them, not us.
        let big = Self.makeEvent(type: .leftMouseDragged, dx: Self.threshold + 10)
        let trailingMouseUp = Self.makeEvent(type: .leftMouseUp)
        let q = EventQueue([
            Self.makeEvent(type: .leftMouseDragged, dx: 1),
            Self.makeEvent(type: .leftMouseDragged, dx: 2),
            big,
            trailingMouseUp,
        ])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        guard case .drag(let returned) = result else {
            XCTFail("Expected .drag once movement crossed threshold, got \(result)")
            return
        }
        XCTAssertTrue(returned === big,
                      "Drag initiator must be the FIRST past-threshold event, not a later one.")
        XCTAssertEqual(q.events.count, 1,
                       "The function must stop reading events once it returns .drag — the trailing mouseUp should still be in the queue for performDrag to consume.")
        XCTAssertTrue(q.events.first === trailingMouseUp,
                      "The single remaining event must be the trailing mouseUp.")
    }

    func test_empty_event_stream_returns_tap() {
        // Defensive: in production NSApp.nextEvent waits forever, so
        // we never see an empty stream. In tests we hand the function
        // an exhausted queue — it should fall through to .tap rather
        // than spin.
        let q = EventQueue([])
        let result = FloatingPillWindow.trackDragOrTap(
            startLocation: Self.pressLocation,
            threshold: Self.threshold,
            nextEvent: { q.next() }
        )
        XCTAssertEqual(result, .tap, "Exhausted event stream should fall through to .tap, not loop forever.")
    }

    // MARK: - MouseTrackResult equality

    func test_mouseTrackResult_equality_is_case_only() {
        // We only need to compare .tap == .tap in tests; .drag carries
        // an NSEvent that has no Equatable conformance, and we don't
        // want to require one. Verify our local Equatable shim handles
        // the cases sensibly.
        XCTAssertEqual(FloatingPillWindow.MouseTrackResult.tap,
                       FloatingPillWindow.MouseTrackResult.tap)
        let e = Self.makeEvent(type: .leftMouseDragged)
        XCTAssertNotEqual(FloatingPillWindow.MouseTrackResult.tap,
                          FloatingPillWindow.MouseTrackResult.drag(e))
    }
}

// MARK: - Equatable shim for assertions
//
// MouseTrackResult intentionally doesn't conform to Equatable in the
// production module (NSEvent has no Equatable conformance and we don't
// want to hand-roll one). For test ergonomics we provide a same-case
// equality here — XCTAssertEqual then works for the common patterns.
extension FloatingPillWindow.MouseTrackResult: Equatable {
    public static func == (
        lhs: FloatingPillWindow.MouseTrackResult,
        rhs: FloatingPillWindow.MouseTrackResult
    ) -> Bool {
        switch (lhs, rhs) {
        case (.tap, .tap): return true
        case (.drag, .drag): return true
        default: return false
        }
    }
}
