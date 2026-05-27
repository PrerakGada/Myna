// GestureRouter.swift — translates a recognised gesture into an
// AppDispatcher action. Decoupled from GestureMonitor so the monitor
// can stay pure NSEvent plumbing and the router can be unit-tested
// against a fake dispatcher.
import Foundation

/// The semantic gesture vocabulary Myna recognises. Keep this stable —
/// onboarding docs and the System Settings note both reference these names.
public enum MynaGesture: String, Sendable, CaseIterable {
    /// 4-finger trackpad tap → trigger speak-selection (same effect as the hotkey).
    /// NOTE: not implementable with public global NSEvent APIs today; we
    /// surface this as a known limitation and recommend a Hammerspoon
    /// recipe in the Settings tab.
    case fourFingerTap

    /// 4-finger trackpad swipe left → previous chunk.
    /// Implemented via global NSEvent `.swipe`. Conflicts with the macOS
    /// "Swipe between full-screen apps" default; users must either
    /// re-bind that to 3 fingers or disable Mission Control's 4-finger
    /// gestures in System Settings → Trackpad → More Gestures.
    case fourFingerSwipeLeft

    /// 4-finger trackpad swipe right → next chunk. Same caveat as above.
    case fourFingerSwipeRight

    /// 3-finger force-touch click → toggle pause/resume.
    /// Implemented via NSEvent `.pressure` with `stage >= 2` (the
    /// system's hard click threshold). Requires Force Touch trackpad
    /// hardware. We accept whatever finger count was on the trackpad
    /// at the moment of click — the OS doesn't expose touch count on
    /// global pressure events, so the "3-finger" part is best-effort.
    case threeFingerForceClick
}

/// Pluggable target so the router can be unit-tested.
@MainActor
public protocol GestureActionTarget: AnyObject {
    func speakSelection(mode: SynthesizeMode)
    func togglePause()
    func seek(delta: TimeInterval)
}

/// Dispatch each recognised gesture to the action target. Keeps the
/// gesture → action mapping in one place; the AppDispatcher conforms
/// to GestureActionTarget so production wiring is one line.
@MainActor
public final class GestureRouter {
    private weak var target: (any GestureActionTarget)?
    private let log = Log(.app)

    /// Seek amount we use to approximate "previous chunk / next chunk".
    /// The Swift player has no notion of chunks, so the cleanest
    /// public-API substitute is a longish jump on the virtual timeline.
    /// 30 s matches the seek menu's largest step.
    public static let chunkSeekSeconds: TimeInterval = 30

    public init(target: any GestureActionTarget) {
        self.target = target
    }

    public func handle(_ gesture: MynaGesture) {
        guard let target else { return }
        switch gesture {
        case .fourFingerTap:
            target.speakSelection(mode: .full)
        case .fourFingerSwipeLeft:
            target.seek(delta: -Self.chunkSeekSeconds)
        case .fourFingerSwipeRight:
            target.seek(delta: Self.chunkSeekSeconds)
        case .threeFingerForceClick:
            target.togglePause()
        }
        log.info("gesture handled: \(gesture.rawValue)")
    }
}
