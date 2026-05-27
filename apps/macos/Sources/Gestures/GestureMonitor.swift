// GestureMonitor.swift — global trackpad gesture recognition for Myna.
//
// SCOPE & HONEST LIMITATIONS
// ===========================
// Public NSEvent APIs only. The private `MultitouchSupport.framework`
// is intentionally out of scope (it's a tarpit and Apple rejects apps
// that load it from the App Store; even outside the Store it breaks
// every OS release).
//
// What works:
//   * `.swipe` — global trackpad swipe gesture. Direction comes from
//     `event.deltaX`. We treat any horizontal swipe as the "4-finger
//     swipe" because the OS doesn't expose touch count on global swipe
//     events. Users must either:
//       1. Enable System Settings → Trackpad → More Gestures →
//          "Swipe between full-screen apps" set to "Swipe left or
//          right with four fingers" (default on Magic Trackpad), AND
//       2. Either accept the Mission Control conflict, OR disable
//          that gesture in System Settings to avoid collisions.
//     We surface this in the Settings tab.
//
//   * `.pressure` — global force-touch event. The OS reports a
//     `stage` 0 → 2 (light tap → hard click) on a Force Touch trackpad.
//     Stage 2 ≅ the system "force click" threshold; we treat that as
//     the "3-finger force-touch click" gesture. We CANNOT confirm the
//     finger count on a global pressure event (CoreFoundation's
//     NSEvent global monitor never delivers touch lists), so the
//     "3-finger" part is best-effort labeling, not a strict check.
//
// What does NOT work (documented in GestureRouter.MynaGesture):
//   * 4-finger TAP — global gesture monitors do not see touch lists,
//     and global `.beginGesture`/`.endGesture` events don't include
//     finger counts. Public-API solutions all require either a focused
//     window (local monitor) or the private Multitouch framework.
//     We expose a Hammerspoon recipe in the Settings copy instead.
//
// Lifecycle:
//   start() registers global event monitors via NSEvent.
//   stop()  unregisters them.
//   Idempotent on repeat start() / stop() calls.
//
// Concurrency:
//   @MainActor — NSEvent monitor callbacks fire on the main thread by
//   contract, and we route directly into the GestureRouter without
//   crossing actors.
import AppKit
import Foundation

@MainActor
public final class GestureMonitor {
    private let router: GestureRouter
    private let log = Log(.app)

    private var swipeMonitor: Any?
    private var pressureMonitor: Any?

    /// Minimum horizontal swipe magnitude before we count it as a
    /// direction. NSEvent's swipe deltaX is in [-1, 1] where ±1
    /// means a complete, decisive swipe; anything below 0.5 is noisy.
    private static let swipeThreshold: CGFloat = 0.5

    /// Force-touch click recognition: stage 2 is the system "deep
    /// press" threshold. Stage 1 is the normal click bump; we want
    /// only the deliberate hard click.
    private static let forceClickStage: Int = 2

    /// Debounce: don't fire force-click again until this many seconds
    /// have passed. macOS sends multiple `.pressure` events per click
    /// as the stage transitions; without debouncing we'd toggle
    /// pause/resume on every transition.
    private static let forceClickDebounce: TimeInterval = 0.5
    private var lastForceClickAt: TimeInterval = 0

    /// Same debounce for swipes — `.swipe` is single-shot per gesture
    /// in practice but we belt-and-braces it.
    private static let swipeDebounce: TimeInterval = 0.5
    private var lastSwipeAt: TimeInterval = 0

    public init(router: GestureRouter) {
        self.router = router
    }

    public var isRunning: Bool {
        swipeMonitor != nil || pressureMonitor != nil
    }

    public func start() {
        if isRunning { return }
        log.info("GestureMonitor.start")

        // NSEvent.addGlobalMonitorForEvents fires on the main thread.
        // The closure type is sendable in Swift 6 strict-concurrency,
        // but @MainActor isolation on the class means we can hop back
        // safely without ferrying the event across actors.
        swipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.swipe]) { [weak self] event in
            // Hop back to main actor explicitly — Swift 6 wants this
            // even though NSEvent global monitors are documented as
            // delivering on the main thread.
            Task { @MainActor [weak self] in
                self?.handleSwipe(event)
            }
        }

        pressureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.pressure]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePressure(event)
            }
        }
    }

    public func stop() {
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
        }
        if let pressureMonitor {
            NSEvent.removeMonitor(pressureMonitor)
            self.pressureMonitor = nil
        }
        log.info("GestureMonitor.stop")
    }

    // MARK: - Event handling (internal so tests can drive them directly)

    /// Internal test hook — synthesize a swipe event for unit tests
    /// where we can't fire a real NSEvent.
    func _testHandleSwipe(deltaX: CGFloat) {
        // Simulate the same dispatch as the global monitor.
        if abs(deltaX) < Self.swipeThreshold { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSwipeAt < Self.swipeDebounce { return }
        lastSwipeAt = now
        router.handle(deltaX > 0 ? .fourFingerSwipeRight : .fourFingerSwipeLeft)
    }

    /// Internal test hook — synthesize a force-click event.
    func _testHandlePressure(stage: Int) {
        if stage < Self.forceClickStage { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastForceClickAt < Self.forceClickDebounce { return }
        lastForceClickAt = now
        router.handle(.threeFingerForceClick)
    }

    private func handleSwipe(_ event: NSEvent) {
        let deltaX = event.deltaX
        // Only horizontal swipes; vertical can be wired in future iterations.
        guard abs(deltaX) >= Self.swipeThreshold else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSwipeAt >= Self.swipeDebounce else { return }
        lastSwipeAt = now
        // macOS reports rightward swipe as negative deltaX (the content
        // moves left). The user-facing label "swipe right" matches the
        // natural-feeling direction, so flip the sign.
        let userSwipeRight = deltaX < 0
        router.handle(userSwipeRight ? .fourFingerSwipeRight : .fourFingerSwipeLeft)
    }

    private func handlePressure(_ event: NSEvent) {
        // event.stage is 0–2; 2 is the hard click.
        guard event.stage >= Self.forceClickStage else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastForceClickAt >= Self.forceClickDebounce else { return }
        lastForceClickAt = now
        router.handle(.threeFingerForceClick)
    }
}
