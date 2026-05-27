// MultitouchBridge.swift — runtime-loaded bridge to Apple's private
// MultitouchSupport.framework, plus a global NSEvent `.pressure`
// monitor for force-click stages.
//
// WHY PRIVATE FRAMEWORK
// ---------------------
// Public NSEvent global monitors do not include the per-event touch
// list — only locally-installed monitors bound to a focused view get
// `event.touches(matching:in:)`. To detect "exactly N fingers on the
// trackpad right now" globally we have to read MT data directly from
// the HID stack. Apple's private `MultitouchSupport.framework` is the
// canonical channel; it's been used by BetterTouchTool, Magnet, Cinch,
// Hammerspoon, Karabiner-Elements and every Mac multitouch utility for
// the last 15+ years.
//
// Myna ships outside the App Store (Homebrew tap + direct DMG +
// Sparkle updates), so private-framework use is acceptable per
// project distribution policy. If Apple ever revokes the framework
// this bridge will fail safely: `MTDeviceCreateDefault` returns nil
// and the bridge logs a warning, leaving the rest of the app fully
// functional minus the gesture feature.
//
// LINKAGE
// -------
// We deliberately **do not** link MultitouchSupport at compile time —
// no entry in project.yml's `link` section, no `import` (there are no
// public headers anyway). Instead we `dlopen` at start-up and `dlsym`
// the five functions we use. This keeps the binary launchable even on
// systems / Apple Silicon transitions where the framework moves path.
//
// CONCURRENCY
// -----------
// The MT contact-frame callback fires on a private HID dispatch thread
// at ~60 Hz. We hop straight to the main actor before touching the
// recognizer or the router; the recognizer is intentionally not
// thread-safe and the GestureRouter is `@MainActor`.
//
// LIFECYCLE
// ---------
// `start()` opens the framework, builds the default trackpad device,
// installs the contact callback, registers the global pressure
// monitor, and starts a one-shot timer for the recognizer's pending
// emissions.
//
// `stop()` tears all of that down. Idempotent. The recognizer is
// retained across start/stop cycles so state stays clean across
// settings-toggle thrash.
import AppKit
import Foundation
import os.lock

/// C function-pointer signatures dlsym'd at runtime. Documented widely
/// across MT reverse-engineering blogs; the `Finger` C struct is large
/// (~80 bytes) but we never deref individual fields, we only read the
/// `nFingers` argument.
private typealias MTDeviceRef = OpaquePointer
private typealias MTDeviceCreateDefaultFn = @convention(c) (Int32) -> MTDeviceRef?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (
    MTDeviceRef?, MTContactFrameCallbackC?
) -> Void
private typealias MTUnregisterContactFrameCallbackFn = @convention(c) (
    MTDeviceRef?, MTContactFrameCallbackC?
) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef?, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef?) -> Void
private typealias MTDeviceReleaseFn = @convention(c) (MTDeviceRef?) -> Void

/// The MT contact-frame callback prototype. We don't need to inspect
/// the per-finger `Finger` array — only the count — so the `data`
/// pointer is left typed-erased.
private typealias MTContactFrameCallbackC = @convention(c) (
    Int32,                      // deviceId
    UnsafeMutableRawPointer?,   // Finger *data — opaque to us
    Int32,                      // nFingers
    Double,                     // timestamp (absolute, seconds)
    Int32                       // frame number
) -> Int32

// The C callback cannot capture `self`, so we shuttle the most-recent
// finger count through a process-global lock-guarded slot. The bridge
// instance polls / drains this on its serial dispatch queue.
//
// This is uglier than a userdata pointer but MultitouchSupport's
// contact-frame callback does not accept a context pointer in its
// classic signature, so a static sink is the path of least resistance.
private struct LatestFrame {
    var timestamp: TimeInterval
    var fingerCount: Int
}

private final class CallbackSink: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var latest: LatestFrame?

    func push(_ frame: LatestFrame) {
        os_unfair_lock_lock(&lock)
        latest = frame
        os_unfair_lock_unlock(&lock)
    }

    func drain() -> LatestFrame? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let out = latest
        latest = nil
        return out
    }
}

private let sharedSink = CallbackSink()

// The C trampoline. Stays at file scope so it has stable @convention(c).
private let multitouchCContactCallback: MTContactFrameCallbackC = { _, _, nFingers, timestamp, _ in
    sharedSink.push(LatestFrame(timestamp: timestamp, fingerCount: Int(nFingers)))
    return 0
}

/// Outcome of `MultitouchBridge.start()`.
public enum MultitouchBridgeStartResult: Equatable, Sendable {
    case started
    /// dlopen returned nil — framework missing from `/System/Library/PrivateFrameworks`.
    case frameworkMissing
    /// dlsym failed for one of the required symbols.
    case symbolMissing(String)
    /// `MTDeviceCreateDefault` returned nil — no trackpad attached, or
    /// Apple changed the device discovery path.
    case noTrackpad
}

@MainActor
public final class MultitouchBridge {
    private let router: GestureRouter
    private let log = Log(.app)

    // dlopen handle + dlsym pointers. nil when stopped.
    private var dlHandle: UnsafeMutableRawPointer?
    private var device: MTDeviceRef?
    private var fnDeviceCreateDefault: MTDeviceCreateDefaultFn?
    private var fnRegisterCallback: MTRegisterContactFrameCallbackFn?
    private var fnUnregisterCallback: MTUnregisterContactFrameCallbackFn?
    private var fnDeviceStart: MTDeviceStartFn?
    private var fnDeviceStop: MTDeviceStopFn?
    private var fnDeviceRelease: MTDeviceReleaseFn?

    // NSEvent pressure monitor. nil when stopped.
    private var pressureMonitor: Any?

    // Polling timer that drains `sharedSink` on the main actor and
    // ticks the recognizer. We poll at ~120 Hz so a tap that lifts
    // between MT frames still gets a timely classification.
    private var drainTimer: Timer?

    // One-shot timer that fires when the recognizer has a pending
    // emission waiting on `doubleClickInterval` to elapse.
    private var pendingFlushTimer: Timer?

    private let recognizer: GestureRecognizer4Finger

    /// Framework path. Stored so tests / debug builds can swap it for
    /// a stub. The bridge is unit-testable indirectly via the
    /// recognizer; this hook is for manual smoke-testing.
    public static let defaultFrameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    public init(router: GestureRouter) {
        self.router = router
        // Latency tuning: NSEvent.doubleClickInterval is the user's
        // *mouse* double-click setting — typically 500 ms. That's too
        // slow for trackpad gestures (users perform a 4-finger double
        // tap in 150–250 ms; waiting 500 ms before firing the single
        // tap feels broken). BTT, Magnet, and the other multitouch
        // utilities settle around 250–300 ms. We do the same:
        //   * cap at 300 ms by default (snappy single-tap)
        //   * respect users on the slow end of NSEvent — accessibility
        //     setups configure that low for a reason (motor-impaired
        //     users genuinely need more time between events)
        let systemInterval = NSEvent.doubleClickInterval
        let trackpadInterval = min(systemInterval, 0.300)
        let cfg = GestureRecognizerConfig(
            doubleClickInterval: trackpadInterval
        )
        // We can't capture `self` in the recognizer's emit closure
        // before `self.recognizer` is assigned. Bounce through a
        // mutable closure ref: the recognizer reads the ref's value,
        // and we set the value (a self-capturing closure) immediately
        // after super-init has settled all stored properties.
        let ref = ClosureRef()
        self.emitClosureRef = ref
        self.recognizer = GestureRecognizer4Finger(config: cfg) { gesture in
            ref.value(gesture)
        }
        // Now safe to capture self.
        self.emitClosureRef.value = { [weak self] gesture in
            self?.dispatch(gesture)
        }
    }

    /// Mutable closure ref. The recognizer reads `emitClosureRef.value`
    /// at dispatch time so we can finalize `self` capture post-init.
    private final class ClosureRef: @unchecked Sendable {
        var value: (FourFingerGesture) -> Void = { _ in }
    }
    private let emitClosureRef: ClosureRef

    private func dispatch(_ gesture: FourFingerGesture) {
        switch gesture {
        case .tap: router.handle(.fourFingerTap)
        case .doubleTap: router.handle(.fourFingerDoubleTap)
        case .click: router.handle(.fourFingerClick)
        case .doubleClick: router.handle(.fourFingerDoubleClick)
        }
    }

    public var isRunning: Bool {
        device != nil || pressureMonitor != nil || drainTimer != nil
    }

    @discardableResult
    public func start() -> MultitouchBridgeStartResult {
        if isRunning { return .started }
        log.info("MultitouchBridge.start")

        // 1. dlopen
        guard let handle = dlopen(Self.defaultFrameworkPath, RTLD_LAZY) else {
            log.warn("MultitouchSupport.framework not loadable — gestures disabled")
            return .frameworkMissing
        }
        self.dlHandle = handle

        // 2. dlsym the entry points. Bail on the first missing symbol;
        //    a partial bind would crash later.
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        guard let createFn = sym("MTDeviceCreateDefault", as: MTDeviceCreateDefaultFn.self) else {
            cleanupDl()
            return .symbolMissing("MTDeviceCreateDefault")
        }
        guard let registerFn = sym(
            "MTRegisterContactFrameCallback",
            as: MTRegisterContactFrameCallbackFn.self
        ) else {
            cleanupDl()
            return .symbolMissing("MTRegisterContactFrameCallback")
        }
        let unregisterFn = sym(
            "MTUnregisterContactFrameCallback",
            as: MTUnregisterContactFrameCallbackFn.self
        )
        guard let startFn = sym("MTDeviceStart", as: MTDeviceStartFn.self) else {
            cleanupDl()
            return .symbolMissing("MTDeviceStart")
        }
        guard let stopFn = sym("MTDeviceStop", as: MTDeviceStopFn.self) else {
            cleanupDl()
            return .symbolMissing("MTDeviceStop")
        }
        let releaseFn = sym("MTDeviceRelease", as: MTDeviceReleaseFn.self)
        self.fnDeviceCreateDefault = createFn
        self.fnRegisterCallback = registerFn
        self.fnUnregisterCallback = unregisterFn
        self.fnDeviceStart = startFn
        self.fnDeviceStop = stopFn
        self.fnDeviceRelease = releaseFn

        // 3. Make device + register callback. The constant 0 is the
        //    default-device flag per MT reverse-engineering convention.
        guard let dev = createFn(0) else {
            log.warn("MTDeviceCreateDefault returned nil — no trackpad found")
            cleanupDl()
            return .noTrackpad
        }
        self.device = dev
        registerFn(dev, multitouchCContactCallback)
        startFn(dev, 0)

        // 4. Global click NSEvent monitor.
        //
        // We originally listened to `.pressure` — but those events only
        // fire for Force Touch (the *deep press* used by Look Up / Quick
        // Look). A normal trackpad click is `.leftMouseDown` with no
        // pressure event behind it, so users doing a regular 4-finger
        // click got nothing. Switching to `.leftMouseDown` also
        // automatically extends click gestures to pre-2015 trackpads
        // that have no Force Touch sensor at all.
        //
        // The recognizer expects a "stage" — we synthesize stage=2 to
        // satisfy its existing `stage >= clickStage` filter without
        // changing the type. The state machine treats every `.leftMouseDown`
        // that arrives while 4 fingers are touching as the click gesture;
        // clicks with fewer than 4 fingers are ignored in the `.idle`
        // branch so we don't intercept normal app clicks.
        pressureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ts = ProcessInfo.processInfo.systemUptime
                self.recognizer.onPressure(GesturePressureEvent(timestamp: ts, stage: 2))
                self.scheduleFlushIfNeeded()
            }
        }

        // 5. Drain timer. We poll the sharedSink instead of taking the
        //    callback path because the MT callback runs on its own
        //    thread and we already have a clean main-actor delivery
        //    mechanism via Timer.
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop already, but Swift
            // strict concurrency wants the hop made explicit.
            Task { @MainActor [weak self] in
                self?.drainAndTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.drainTimer = timer

        log.info("MultitouchBridge ready — device + pressure monitor + drain timer up")
        return .started
    }

    public func stop() {
        if !isRunning { return }
        log.info("MultitouchBridge.stop")

        if let dev = device {
            fnDeviceStop?(dev)
            if let unregister = fnUnregisterCallback {
                unregister(dev, multitouchCContactCallback)
            }
            fnDeviceRelease?(dev)
        }
        device = nil

        if let monitor = pressureMonitor {
            NSEvent.removeMonitor(monitor)
        }
        pressureMonitor = nil

        drainTimer?.invalidate()
        drainTimer = nil
        pendingFlushTimer?.invalidate()
        pendingFlushTimer = nil

        cleanupDl()
    }

    // MARK: - Private

    private func cleanupDl() {
        if let handle = dlHandle {
            // dlclose is not strictly required for system frameworks
            // and some refcounted system libs misbehave when closed
            // out from under their internal callers. We leave the
            // handle open — the OS reclaims on process exit.
            _ = handle
        }
        dlHandle = nil
        fnDeviceCreateDefault = nil
        fnRegisterCallback = nil
        fnUnregisterCallback = nil
        fnDeviceStart = nil
        fnDeviceStop = nil
        fnDeviceRelease = nil
    }

    private func drainAndTick() {
        if let frame = sharedSink.drain() {
            recognizer.onTouchFrame(GestureTouchFrame(
                timestamp: frame.timestamp,
                fingerCount: frame.fingerCount
            ))
        }
        recognizer.flushIfDue(at: ProcessInfo.processInfo.systemUptime)
        scheduleFlushIfNeeded()
    }

    /// Make sure a one-shot timer is scheduled to fire when the
    /// recognizer's pending tap/click ages out, in case no further
    /// touch frames arrive between now and then.
    private func scheduleFlushIfNeeded() {
        guard let deadline = recognizer.pendingDeadline() else {
            pendingFlushTimer?.invalidate()
            pendingFlushTimer = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(0.005, deadline - now)
        pendingFlushTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recognizer.flushIfDue(at: ProcessInfo.processInfo.systemUptime)
                self.scheduleFlushIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingFlushTimer = timer
    }

    // MARK: - Test hooks (internal)

    // Leading underscore is intentional on these two test hooks:
    // signals "test-only API, not part of the public surface" without
    // factoring them into a separate testing protocol.
    // swiftlint:disable identifier_name

    /// Inject a touch frame synthetically — used by integration smoke
    /// tests that don't have a real trackpad. Bypasses the C callback.
    func _testInjectFrame(_ frame: GestureTouchFrame) {
        recognizer.onTouchFrame(frame)
    }

    /// Inject a pressure event synthetically; companion to
    /// `_testInjectFrame` for the click side of the state machine.
    func _testInjectPressure(_ event: GesturePressureEvent) {
        recognizer.onPressure(event)
    }
    // swiftlint:enable identifier_name
}
