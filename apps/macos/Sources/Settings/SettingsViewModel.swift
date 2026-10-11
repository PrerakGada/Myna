// SettingsViewModel.swift — view model backing the SwiftUI Settings
// window. All persistent values live in UserDefaults under the
// `dev.myna.app.*` keyspace, accessed via the SettingsStore wrapper so
// tests can inject a non-standard suite.
//
// Implementation note: we use the ObservableObject / @Published pattern
// because the project's deployment target is macOS 13.0 Ventura and
// @Observable requires 14.0+. Once 13.0 support is dropped this can be
// migrated to @Observable in a single targeted edit (every property
// loses `@Published` and the class gains `@Observable`).
import Combine
import Foundation

/// Stable key names. All prefixed with `dev.myna.app.` so they don't
/// collide with anything else in the user's defaults.
public enum SettingsKey: String, CaseIterable, Sendable {
    case voice = "dev.myna.app.voice"
    case defaultSpeed = "dev.myna.app.defaultSpeed"
    case summaryMode = "dev.myna.app.summaryMode"
    case daemonURL = "dev.myna.app.daemonURL"
    case daemonPort = "dev.myna.app.daemonPort"
    case engineURL = "dev.myna.app.engineURL"
    case enginePort = "dev.myna.app.enginePort"
    case logLevel = "dev.myna.app.logLevel"
    case useNotifications = "dev.myna.app.useNotifications"
    // v0.2 behavior toggles (S08 toast chime + focus mode)
    /// Tone fired the instant a trackpad gesture is recognised. Replaced the
    /// v0.2 thinking-onset earcon (`dev.myna.app.thinkingEarconEnabled`,
    /// now unused — stale values are harmless).
    case gestureEarconEnabled = "dev.myna.app.gestureEarconEnabled"
    case toastChimeEnabled = "dev.myna.app.toastChimeEnabled"
    case ccToastsEnabled = "dev.myna.app.ccToastsEnabled"
    /// v0.2: opt-in trackpad gesture recognition. Default OFF — we
    /// don't want to surprise users with a 4-finger swipe that
    /// silently jumps chunks.
    case trackpadGesturesEnabled = "dev.myna.app.trackpadGesturesEnabled"
    /// v0.2.x: keep the floating pill on screen whenever Myna is
    /// running, not just while speaking. Default OFF — Wispr-Flow-style
    /// always-visible chip is a power-user opt-in.
    case pillAlwaysVisible = "dev.myna.app.pillAlwaysVisible"
    /// While Myna reads, the pill opens into a caption: the sentence being
    /// read, its spoken word lit. Default ON.
    case pillLiveCaptions = "dev.myna.app.pillLiveCaptions"
    /// v0.2.x: one-shot playback — buffer the whole clip before playing
    /// so playback is gap-free (no mid-clip stall while the daemon
    /// synthesizes later chunks). Default ON. OFF restores streaming
    /// (fast first-audio, chunks play as they arrive).
    case oneShotPlayback = "dev.myna.app.oneShotPlayback"
    /// Read only the **bold** claims of a Claude Code reply (falls back to
    /// the whole reply when it has none). Default OFF — it only pays off
    /// when the writer bolds whole claims, not keywords.
    case ccBoldClaimsOnly = "dev.myna.app.ccBoldClaimsOnly"
    /// How the read shortcut captures the selection: "automatic"
    /// (Accessibility, then ⌘C) or "copy" (⌘C only). See SelectionService.
    case selectionCapture = "dev.myna.app.selectionCapture"
    /// Clean text up before reading it (markdown, code, URLs, citation
    /// marks). Default ON. Per-source switches below; see TextCleanupSettings.
    case textCleanup = "dev.myna.app.textCleanup"
    case textCleanupClaudeCode = "dev.myna.app.textCleanupClaudeCode"
    case textCleanupArticles = "dev.myna.app.textCleanupArticles"
    case textCleanupSelection = "dev.myna.app.textCleanupSelection"
}

/// Built-in defaults — must mirror the daemon's config defaults so the
/// app behaves correctly before the user has ever opened Settings.
public enum SettingsDefaults {
    public static let voice = "af_heart"
    public static let defaultSpeed: Double = 1.0
    public static let summaryMode: Bool = false
    public static let daemonURL = "http://127.0.0.1"
    public static let daemonPort: Int = 8_766
    public static let engineURL = "http://127.0.0.1"
    public static let enginePort: Int = 8_765
    public static let logLevel: String = LogLevel.info.rawValue
    public static let useNotifications: Bool = false
    // Gesture earcon ON by default: a trackpad gesture has no visual
    // confirmation at the moment of contact, so silence is indistinguishable
    // from a missed gesture. Toast chime ON (gentle 60ms tick), toasts ON.
    public static let gestureEarconEnabled: Bool = true
    public static let toastChimeEnabled: Bool = true
    public static let ccToastsEnabled: Bool = true
    /// v0.2: trackpad gestures default OFF. See SettingsKey docs.
    public static let trackpadGesturesEnabled: Bool = false
    /// v0.2.x: floating-pill always-visible default OFF. The
    /// existing "Show floating pill while speaking" master toggle
    /// still gates everything; this only widens *when* the pill
    /// appears, never overrides the master kill switch.
    public static let pillAlwaysVisible: Bool = false
    /// Live captions in the pill default ON: seeing what Myna reads, from
    /// any app or from Claude Code, is the point of the pill while it reads.
    public static let pillLiveCaptions: Bool = true
    /// v0.2.x: one-shot playback default ON. Most users prefer the
    /// whole clip ready and gap-free over fast-but-stuttering first
    /// audio. Power users can flip it off for streaming.
    public static let oneShotPlayback: Bool = true
    /// Bold-claims-only reading of Claude Code replies default OFF. See
    /// SettingsKey docs.
    public static let ccBoldClaimsOnly: Bool = false
    /// Accessibility first: it leaves the clipboard alone. "Copy only" is
    /// the escape hatch for an app whose AX answer is wrong.
    public static let selectionCapture: SelectionCaptureMode = .automatic
    /// Text cleanup defaults ON, for every source.
    public static let textCleanup: Bool = true
    public static let textCleanupClaudeCode: Bool = true
    public static let textCleanupArticles: Bool = true
    public static let textCleanupSelection: Bool = true
}

/// Thin wrapper over UserDefaults so tests can inject an ephemeral
/// suite without touching the user's plist.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore(defaults: .standard)

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func string(_ key: SettingsKey) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    public func double(_ key: SettingsKey) -> Double? {
        defaults.object(forKey: key.rawValue) as? Double
    }

    public func int(_ key: SettingsKey) -> Int? {
        defaults.object(forKey: key.rawValue) as? Int
    }

    public func bool(_ key: SettingsKey) -> Bool? {
        defaults.object(forKey: key.rawValue) as? Bool
    }

    public func set(_ key: SettingsKey, _ value: Any?) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    /// Wipe every dev.myna.app.* key in the underlying suite. Used by
    /// the "Reset All Settings" button.
    public func resetAll() {
        for key in SettingsKey.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}

@MainActor
public final class SettingsViewModel: ObservableObject {
    private let store: SettingsStore

    @Published public var voice: String { didSet { store.set(.voice, voice) } }
    @Published public var defaultSpeed: Double {
        didSet {
            let clamped = max(0.5, min(2.0, defaultSpeed))
            if clamped != defaultSpeed {
                defaultSpeed = clamped
                return  // setter re-runs; persist once
            }
            store.set(.defaultSpeed, defaultSpeed)
        }
    }
    @Published public var summaryMode: Bool { didSet { store.set(.summaryMode, summaryMode) } }
    @Published public var daemonURL: String { didSet { store.set(.daemonURL, daemonURL) } }
    @Published public var daemonPort: Int { didSet { store.set(.daemonPort, daemonPort) } }
    @Published public var engineURL: String { didSet { store.set(.engineURL, engineURL) } }
    @Published public var enginePort: Int { didSet { store.set(.enginePort, enginePort) } }
    @Published public var logLevel: String { didSet { store.set(.logLevel, logLevel) } }
    @Published public var useNotifications: Bool { didSet { store.set(.useNotifications, useNotifications) } }
    @Published public var gestureEarconEnabled: Bool {
        didSet { store.set(.gestureEarconEnabled, gestureEarconEnabled) }
    }
    @Published public var toastChimeEnabled: Bool {
        didSet { store.set(.toastChimeEnabled, toastChimeEnabled) }
    }
    @Published public var ccToastsEnabled: Bool {
        didSet { store.set(.ccToastsEnabled, ccToastsEnabled) }
    }
    /// v0.2: opt-in trackpad gesture recognition. Read by AppDelegate
    /// to decide whether to spin up GestureMonitor.
    @Published public var trackpadGesturesEnabled: Bool {
        didSet { store.set(.trackpadGesturesEnabled, trackpadGesturesEnabled) }
    }
    /// v0.2.x: keep the floating pill visible whenever Myna is
    /// running, regardless of playback state. Read by PillController
    /// when deciding visibility (see PillController.syncVisibility).
    @Published public var pillAlwaysVisible: Bool {
        didSet { store.set(.pillAlwaysVisible, pillAlwaysVisible) }
    }
    /// The pill shows the sentence being read, word by word (LiveCaptions).
    @Published public var pillLiveCaptions: Bool {
        didSet { store.set(.pillLiveCaptions, pillLiveCaptions) }
    }
    /// v0.2.x: one-shot playback. Read by AppDispatcher.synthesizeAndPlay
    /// to decide whether to buffer all chunks before playing (gap-free)
    /// or stream them as they arrive.
    @Published public var oneShotPlayback: Bool {
        didSet { store.set(.oneShotPlayback, oneShotPlayback) }
    }
    /// Read only the bold claims of a Claude Code reply. Read by the
    /// toast/menu Play (MenuBarController) and the pill's Play
    /// (PillController) via RegistryV2Item.spokenText(boldClaimsOnly:).
    @Published public var ccBoldClaimsOnly: Bool {
        didSet { store.set(.ccBoldClaimsOnly, ccBoldClaimsOnly) }
    }
    /// Read by AppDispatcher.speakSelection on every read, so a change
    /// applies to the next read without a relaunch.
    @Published public var selectionCaptureMode: SelectionCaptureMode {
        didSet { store.set(.selectionCapture, selectionCaptureMode.rawValue) }
    }
    /// Text cleanup, sent with every read as `prep` (textPrep(for:)).
    @Published public var textCleanup: Bool {
        didSet { store.set(.textCleanup, textCleanup) }
    }
    @Published public var textCleanupClaudeCode: Bool {
        didSet { store.set(.textCleanupClaudeCode, textCleanupClaudeCode) }
    }
    @Published public var textCleanupArticles: Bool {
        didSet { store.set(.textCleanupArticles, textCleanupArticles) }
    }
    @Published public var textCleanupSelection: Bool {
        didSet { store.set(.textCleanupSelection, textCleanupSelection) }
    }

    /// Most recent validation error for the daemon URL field. Settings
    /// UI displays this inline. Nil = currently valid.
    @Published public var daemonURLError: String?

    public init(store: SettingsStore = .shared) {
        self.store = store
        self.voice = store.string(.voice) ?? SettingsDefaults.voice
        self.defaultSpeed = store.double(.defaultSpeed) ?? SettingsDefaults.defaultSpeed
        self.summaryMode = store.bool(.summaryMode) ?? SettingsDefaults.summaryMode
        self.daemonURL = store.string(.daemonURL) ?? SettingsDefaults.daemonURL
        self.daemonPort = store.int(.daemonPort) ?? SettingsDefaults.daemonPort
        self.engineURL = store.string(.engineURL) ?? SettingsDefaults.engineURL
        self.enginePort = store.int(.enginePort) ?? SettingsDefaults.enginePort
        self.logLevel = store.string(.logLevel) ?? SettingsDefaults.logLevel
        self.useNotifications = store.bool(.useNotifications) ?? SettingsDefaults.useNotifications
        self.gestureEarconEnabled = store.bool(.gestureEarconEnabled) ?? SettingsDefaults.gestureEarconEnabled
        self.toastChimeEnabled = store.bool(.toastChimeEnabled) ?? SettingsDefaults.toastChimeEnabled
        self.ccToastsEnabled = store.bool(.ccToastsEnabled) ?? SettingsDefaults.ccToastsEnabled
        self.trackpadGesturesEnabled =
            store.bool(.trackpadGesturesEnabled) ?? SettingsDefaults.trackpadGesturesEnabled
        self.pillAlwaysVisible =
            store.bool(.pillAlwaysVisible) ?? SettingsDefaults.pillAlwaysVisible
        self.pillLiveCaptions =
            store.bool(.pillLiveCaptions) ?? SettingsDefaults.pillLiveCaptions
        self.oneShotPlayback =
            store.bool(.oneShotPlayback) ?? SettingsDefaults.oneShotPlayback
        self.ccBoldClaimsOnly =
            store.bool(.ccBoldClaimsOnly) ?? SettingsDefaults.ccBoldClaimsOnly
        // An unknown value (a newer build's mode) degrades to the default.
        self.selectionCaptureMode =
            store.string(.selectionCapture).flatMap(SelectionCaptureMode.init(rawValue:))
            ?? SettingsDefaults.selectionCapture
        self.textCleanup = store.bool(.textCleanup) ?? SettingsDefaults.textCleanup
        self.textCleanupClaudeCode =
            store.bool(.textCleanupClaudeCode) ?? SettingsDefaults.textCleanupClaudeCode
        self.textCleanupArticles =
            store.bool(.textCleanupArticles) ?? SettingsDefaults.textCleanupArticles
        self.textCleanupSelection =
            store.bool(.textCleanupSelection) ?? SettingsDefaults.textCleanupSelection
    }

    /// Validate that the given URL string is localhost-only (we never
    /// want the menu-bar app sending raw text to a remote endpoint).
    /// Returns nil if valid; otherwise an error description.
    public func validateDaemonURL(_ candidate: String) -> String? {
        guard let parsed = URL(string: candidate),
            let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return "must be a valid http(s) URL"
        }
        let host = parsed.host?.lowercased() ?? ""
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            return "must point to localhost (127.0.0.1 or localhost)"
        }
        return nil
    }

    /// Apply the daemon URL after validating it. Returns true on
    /// success; on failure, `daemonURLError` is populated and the value
    /// is not stored.
    @discardableResult
    public func setDaemonURL(_ candidate: String) -> Bool {
        if let err = validateDaemonURL(candidate) {
            daemonURLError = err
            return false
        }
        daemonURLError = nil
        daemonURL = candidate
        return true
    }

    /// Full base URL (`scheme://host:port`) for use by DaemonClient.
    public var fullDaemonBaseURL: URL? {
        let trimmed = daemonURL.trimmingCharacters(in: .whitespaces)
        let asString: String
        if let parsed = URL(string: trimmed), parsed.port != nil {
            asString = trimmed
        } else {
            asString = "\(trimmed):\(daemonPort)"
        }
        return URL(string: asString)
    }

    /// Reset every dev.myna.app.* key to its built-in default. Calling
    /// code should then create a new SettingsViewModel to pick up the
    /// reset state (or read each property fresh).
    public func resetAll() {
        store.resetAll()
        voice = SettingsDefaults.voice
        defaultSpeed = SettingsDefaults.defaultSpeed
        summaryMode = SettingsDefaults.summaryMode
        daemonURL = SettingsDefaults.daemonURL
        daemonPort = SettingsDefaults.daemonPort
        engineURL = SettingsDefaults.engineURL
        enginePort = SettingsDefaults.enginePort
        logLevel = SettingsDefaults.logLevel
        useNotifications = SettingsDefaults.useNotifications
        gestureEarconEnabled = SettingsDefaults.gestureEarconEnabled
        toastChimeEnabled = SettingsDefaults.toastChimeEnabled
        ccToastsEnabled = SettingsDefaults.ccToastsEnabled
        trackpadGesturesEnabled = SettingsDefaults.trackpadGesturesEnabled
        pillAlwaysVisible = SettingsDefaults.pillAlwaysVisible
        oneShotPlayback = SettingsDefaults.oneShotPlayback
        ccBoldClaimsOnly = SettingsDefaults.ccBoldClaimsOnly
        selectionCaptureMode = SettingsDefaults.selectionCapture
        textCleanup = SettingsDefaults.textCleanup
        textCleanupClaudeCode = SettingsDefaults.textCleanupClaudeCode
        textCleanupArticles = SettingsDefaults.textCleanupArticles
        textCleanupSelection = SettingsDefaults.textCleanupSelection
        daemonURLError = nil
    }

    /// Delete the contents of ~/Library/Caches/Myna/. Settings UI binds
    /// this to the "Clear Cache" button.
    @discardableResult
    public func clearCache() -> Bool {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Myna", isDirectory: true)
        guard let cacheDir else { return false }
        if !FileManager.default.fileExists(atPath: cacheDir.path) { return true }
        do {
            try FileManager.default.removeItem(at: cacheDir)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
