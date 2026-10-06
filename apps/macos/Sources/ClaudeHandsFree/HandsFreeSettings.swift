// HandsFreeSettings.swift — the Claude Code hands-free preferences.
//
// Kept out of SettingsViewModel on purpose: the auto-read controller reads
// them at the moment it decides, and the Reading pane's hands-free card binds
// them with @AppStorage, so the shared view model doesn't grow eight more
// properties (and other lanes editing it don't collide with this one). The
// keys share the app's `dev.myna.app.*` space.
import Foundation

public enum HandsFreeKey {
    public static let autoReadWhenAway = "dev.myna.app.ccAutoReadWhenAway"
    public static let speakAlerts = "dev.myna.app.ccSpeakAlerts"
    public static let alertsAtDesk = "dev.myna.app.ccAlertsAtDesk"
    public static let awayWhenLocked = "dev.myna.app.ccAwayWhenLocked"
    public static let awayWhenIdle = "dev.myna.app.ccAwayWhenIdle"
    public static let awayIdleMinutes = "dev.myna.app.ccAwayIdleMinutes"
    public static let awayWhenNotFrontmost = "dev.myna.app.ccAwayWhenNotFrontmost"
    public static let holdDuringCalls = "dev.myna.app.ccHoldDuringCalls"
}

public struct HandsFreeSettings: Equatable, Sendable {
    /// Read a finished reply aloud when it arrives while the user is away.
    public var autoReadWhenAway = false
    /// Speak a short line when a session needs the user (and show it).
    public var speakAlerts = false
    /// Speak those alerts at the desk too, not only while away.
    public var alertsAtDesk = false
    /// Wait while another app is using the microphone.
    public var holdDuringCalls = true
    public var away = AwayPolicy()

    public init() {}

    public static func load(from defaults: UserDefaults = .standard) -> HandsFreeSettings {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            (defaults.object(forKey: key) as? Bool) ?? fallback
        }
        var settings = HandsFreeSettings()
        settings.autoReadWhenAway = bool(HandsFreeKey.autoReadWhenAway, false)
        settings.speakAlerts = bool(HandsFreeKey.speakAlerts, false)
        settings.alertsAtDesk = bool(HandsFreeKey.alertsAtDesk, false)
        settings.holdDuringCalls = bool(HandsFreeKey.holdDuringCalls, true)
        settings.away.whenLocked = bool(HandsFreeKey.awayWhenLocked, true)
        settings.away.whenIdle = bool(HandsFreeKey.awayWhenIdle, true)
        settings.away.whenNotFrontmost = bool(HandsFreeKey.awayWhenNotFrontmost, false)
        if let minutes = defaults.object(forKey: HandsFreeKey.awayIdleMinutes) as? Int {
            settings.away.idleMinutes = minutes
        }
        return settings
    }

    /// What the pill, toast and popover card should show. "Needs you"
    /// entries only appear once the user has turned alerts on, so with the
    /// feature off a newly installed Notification hook changes nothing.
    public static func visiblePending(
        _ items: [RegistryV2Item], defaults: UserDefaults = .standard
    ) -> [RegistryV2Item] {
        if load(from: defaults).speakAlerts { return items }
        return items.filter { !$0.isAttention }
    }
}
