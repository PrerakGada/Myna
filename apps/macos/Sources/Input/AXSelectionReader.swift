// AXSelectionReader.swift — read the selected text through the
// Accessibility API instead of synthesizing ⌘C.
//
// Why this exists: the ⌘C path (SelectionService.captureByCopying) has to
// clear and restore the user's clipboard, wait for the hotkey's modifiers
// to lift, and still fails in apps that ignore a synthetic copy. Asking the
// focused element for `kAXSelectedTextAttribute` touches none of that.
// When AX has no answer, SelectionService falls back to ⌘C unchanged.
//
// Chromium and Electron build their accessibility tree lazily, so until
// someone asks they expose nothing useful. Setting `AXManualAccessibility`
// on the application element makes them build it. We do that at most once
// per process id, and only after a plain read came back empty. We never
// set `AXEnhancedUserInterface`: it is VoiceOver's switch and is known to
// break window animation and positioning in other apps (Rectangle, Magnet
// and friends have all had that bug).
//
// Threading, deliberately: every AX call here is a synchronous mach
// message to *another* process and blocks until that app answers or the
// messaging timeout expires. So the read runs on a private dispatch queue:
//   - not on main, where a busy target app would freeze Myna's menu bar
//     and pill for as long as the target takes to answer;
//   - not on the Swift cooperative pool, whose few threads must never
//     block on IPC.
// AX client calls are CF calls with no AppKit involvement, so they are safe
// off-main. The closures handed to the queue are built in nonisolated code
// (this type is a plain struct, not @MainActor), so they carry no actor
// isolation for Swift 6's runtime check to trap on. See the memories
// `mainactor-closure-on-background-queue` and `macos26-mainactor-callback-trap`.
//
// Testing it by hand: a bare command-line process gets kAXErrorCannotComplete
// (-25204) from the system-wide element even when trusted. Touch
// `NSApplication.shared` first (Myna, being an app, always has), then the
// query works on main and background threads alike.
//
// Time-boxing is two layers: `AXUIElementSetMessagingTimeout` bounds each
// call, and `runWithDeadline` bounds the whole read. A hung app therefore
// costs at most `deadline` before the ⌘C fallback runs. A read that loses
// the race keeps running on the queue until its own calls time out, and
// its result is discarded.
import ApplicationServices
import Foundation

/// What one Accessibility read of the selection produced. Never carries
/// anything but the text itself, so logs built from it stay content-free.
public enum AXSelectionOutcome: Equatable, Sendable {
    /// The focused element reported selected text. It may be empty or
    /// whitespace; the caller decides whether that counts as a selection.
    case text(String)
    /// AX could not answer. `reason` is a short tag for the log, e.g.
    /// `not-trusted` or `no-selected-text(-25212)`.
    case unavailable(reason: String)
    /// The read did not finish inside the deadline (a busy or hung app).
    case timedOut
}

/// Reads the current selection without touching the clipboard. A protocol
/// so SelectionService's fallback chain is testable without real AX.
public protocol SelectionTextReading: Sendable {
    func readSelectedText() async -> AXSelectionOutcome
}

public struct AXSelectionReader: SelectionTextReading {
    /// Per-call AX messaging timeout, in seconds. A responsive app answers
    /// in a few milliseconds; the system default is about 6 s.
    public let messagingTimeout: Float
    /// Ceiling on the whole read, including the one-time Chromium retry.
    public let deadline: TimeInterval
    /// How long to let a Chromium/Electron app build its tree after we set
    /// `AXManualAccessibility`, before asking again.
    public let manualAccessibilitySettle: TimeInterval

    public init(
        messagingTimeout: Float = 0.25,
        deadline: TimeInterval = 0.5,
        manualAccessibilitySettle: TimeInterval = 0.08
    ) {
        self.messagingTimeout = messagingTimeout
        self.deadline = deadline
        self.manualAccessibilitySettle = manualAccessibilitySettle
    }

    /// Concurrent so one read stuck on a hung app never delays the next.
    private static let queue = DispatchQueue(
        label: "dev.myna.input.ax-selection", qos: .userInitiated, attributes: .concurrent)
    /// Processes we have already asked to expose their tree. The attribute
    /// sticks for the life of the process, so asking again is wasted IPC.
    private static let manualAccessibilityPids = PidSet()

    public func readSelectedText() async -> AXSelectionOutcome {
        let timeout = messagingTimeout
        let settle = manualAccessibilitySettle
        return await Self.runWithDeadline(deadline, on: Self.queue, timedOut: .timedOut) {
            Self.read(timeout: timeout, settle: settle, pids: Self.manualAccessibilityPids)
        }
    }

    // MARK: - time-box

    /// Run `work` on `queue` and return its result, or `timedOut` if it has
    /// not finished within `seconds`. Whichever lands first wins; the other
    /// is dropped. Static and nonisolated so the closures it builds carry
    /// no actor isolation onto the queue.
    static func runWithDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        on queue: DispatchQueue,
        timedOut: T,
        work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            queue.async { gate.resume(work()) }
            queue.asyncAfter(deadline: .now() + seconds) { gate.resume(timedOut) }
        }
    }

    // MARK: - the read (runs on `queue`, blocking)

    private static func read(timeout: Float, settle: TimeInterval, pids: PidSet) -> AXSelectionOutcome {
        guard AXIsProcessTrusted() else { return .unavailable(reason: "not-trusted") }
        let system = AXUIElementCreateSystemWide()
        // On the system-wide element this sets the default for every AX
        // call this process makes. The reader is Myna's only AX client.
        AXUIElementSetMessagingTimeout(system, timeout)
        let appResult = copyElement(system, kAXFocusedApplicationAttribute)
        guard case .success(let app) = appResult else {
            return .unavailable(reason: "no-focused-app(\(appResult.code))")
        }
        AXUIElementSetMessagingTimeout(app, timeout)

        let first = selectedText(in: app, timeout: timeout)
        if case .text(let value) = first, !value.isBlank { return first }

        // Nothing usable. If this is a Chromium/Electron app that hasn't
        // built its tree yet, ask it to — once per process — and retry.
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pids.insert(pid) else { return first }
        let status = AXUIElementSetAttributeValue(
            app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Most apps answer "attribute unsupported": not Chromium, so the
        // first answer stands.
        guard status == .success else { return first }
        Thread.sleep(forTimeInterval: settle)
        return selectedText(in: app, timeout: timeout)
    }

    private static func selectedText(in app: AXUIElement, timeout: Float) -> AXSelectionOutcome {
        let focusedResult = copyElement(app, kAXFocusedUIElementAttribute)
        guard case .success(let focused) = focusedResult else {
            return .unavailable(reason: "no-focused-element(\(focusedResult.code))")
        }
        AXUIElementSetMessagingTimeout(focused, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value)
        guard error == .success else {
            return .unavailable(reason: "no-selected-text(\(error.rawValue))")
        }
        guard let text = value as? String else {
            return .unavailable(reason: "selected-text-not-a-string")
        }
        return .text(text)
    }

    private enum ElementResult {
        case success(AXUIElement)
        case failure(AXError)

        var code: Int32 {
            switch self {
            case .success: return 0
            case .failure(let error): return error.rawValue
            }
        }
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> ElementResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return .failure(error) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .failure(.illegalArgument)
        }
        // The type-id check above makes this cast safe.
        return .success(unsafeDowncast(value, to: AXUIElement.self))
    }
}

extension String {
    /// True for "", spaces, tabs and newlines. Selections made of
    /// whitespace only are treated as no selection everywhere in capture.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Resumes a checked continuation exactly once, from whichever thread gets
/// there first. Lock-guarded because the deadline and the work race.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// A thread-safe set of process ids.
private final class PidSet: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    /// Returns true if `pid` was not already present.
    func insert(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pids.insert(pid).inserted
    }
}
