// GestureRouter.swift — translates a recognised gesture into an
// AppDispatcher action. Decoupled from the gesture detection layer
// (MultitouchBridge + GestureRecognizer4Finger) so this stays a thin,
// fully unit-testable mapping.
//
// v0.2.x REDESIGN
// ---------------
// The original v0.2 gesture set was 4-finger swipe + force-touch
// click. Swipe collides with macOS Mission Control ("Swipe between
// full-screen apps" — defaults to 4 fingers on Magic Trackpad) and
// never fires reliably, so we scrapped it. Current set:
//
//   • 4-finger tap          → speak selection (full)
//   • 4-finger press-hold   → speak selection (full)   (emitted as `.click`)
//   • 4-finger double-tap   → stop
//   • 4-finger double-click → stop
//
// CLICK STATUS (2026-06-18)
// macOS never delivers a normal click event to a background app while 4
// fingers rest on the trackpad — the global mouse/pressure monitor stays
// silent (confirmed live). So the physical "4-finger click" is undetectable
// from a background app. Per Prerak's request the deliberate trigger is now a
// 4-finger PRESS-AND-HOLD (~0.3s), which the recognizer emits as `.click`
// using the reliable finger-count stream (the same one the tap uses). Both the
// quick tap and the press-hold speak the selection.
import Foundation

/// The semantic gesture vocabulary Myna recognises.
public enum MynaGesture: String, Sendable, CaseIterable {
    /// 4-finger trackpad tap → speak selection (full).
    case fourFingerTap

    /// 4-finger trackpad double-tap → stop (provisional, until click
    /// path is debugged; canonical mapping is `speakSelection(.summary)`).
    case fourFingerDoubleTap

    /// 4-finger trackpad press-and-hold (~0.3s) → speak selection (full).
    /// Named "click" for historical continuity; the OS click event is
    /// undetectable from a background app, so this is a deliberate hold.
    case fourFingerClick

    /// 4-finger trackpad hard double-click → stop.
    case fourFingerDoubleClick
}

/// Pluggable target so the router can be unit-tested. Implemented by
/// `AppDispatcher` in production.
@MainActor
public protocol GestureActionTarget: AnyObject {
    func speakSelection(mode: SynthesizeMode)
    func togglePause()
    func stop()
    /// Retained from v0.1 for backwards-compat with any internal call
    /// sites; the new gesture set does not use seek but the protocol
    /// keeps it so we don't churn `AppDispatcher`. Removing this would
    /// force a separate `URLSchemeDispatching`-style split.
    func seek(delta: TimeInterval)
}

/// Dispatch each recognised gesture to the action target. Keeps the
/// gesture → action mapping in one place; the AppDispatcher conforms
/// to GestureActionTarget so production wiring is one line.
@MainActor
public final class GestureRouter {
    private weak var target: (any GestureActionTarget)?
    private let log = Log(.app)

    public init(target: any GestureActionTarget) {
        self.target = target
    }

    public func handle(_ gesture: MynaGesture) {
        guard let target else { return }
        switch gesture {
        case .fourFingerTap:
            target.speakSelection(mode: .full)
        case .fourFingerDoubleTap:
            // Double-tap → stop (keeps stop reachable from gestures).
            target.stop()
        case .fourFingerClick:
            // Press-and-hold (~0.3s) → read, per Prerak's request. Same
            // action as tap; the hold is the deliberate, accident-resistant
            // way to trigger a read.
            target.speakSelection(mode: .full)
        case .fourFingerDoubleClick:
            target.stop()
        }
        log.info("gesture handled: \(gesture.rawValue)")
    }
}
