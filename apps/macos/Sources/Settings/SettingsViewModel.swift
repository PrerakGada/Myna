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
