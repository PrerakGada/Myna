// AwayDetector.swift — "is the user away from their desk?" and "are they on a call?"
//
// Claude Code hands-free only talks on its own while the user is away. The
// decision is split in two so it can be tested without a Mac in any
// particular state:
//
//   AwaySignals   what the machine reports right now (AwayProbe reads it)
//   AwayPolicy    which signals the user has switched on
//   AwayDecision  pure: signals + policy (+ the session's host app) → away?
//
// Everything here is polled rather than observed. The controller already
// ticks while it has work, a poll can't deliver a callback on the wrong
// thread (the macOS 26 @MainActor trap), and every read is cheap.
import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Which signals count as "away". Each one is a setting in the Reading pane.
public struct AwayPolicy: Equatable, Sendable {
    /// The screen is locked or the display is asleep.
    public var whenLocked: Bool = true
    /// No keyboard or mouse input for `idleMinutes`.
    public var whenIdle: Bool = true
    public var idleMinutes: Int = AwayPolicy.defaultIdleMinutes
    /// The app the Claude Code session runs in isn't frontmost. Off by
    /// default: plenty of people read replies in another window.
    public var whenNotFrontmost: Bool = false

    public static let defaultIdleMinutes = 2
    public static let idleMinutesRange = 1...30

    public init(
        whenLocked: Bool = true,
        whenIdle: Bool = true,
        idleMinutes: Int = AwayPolicy.defaultIdleMinutes,
        whenNotFrontmost: Bool = false
    ) {
        self.whenLocked = whenLocked
        self.whenIdle = whenIdle
        self.idleMinutes = idleMinutes
        self.whenNotFrontmost = whenNotFrontmost
    }
}

/// A snapshot of the machine's state.
public struct AwaySignals: Equatable, Sendable {
    public var screenLocked: Bool
    public var displayAsleep: Bool
    /// Seconds since the last keyboard, mouse or trackpad event.
    public var idleSeconds: TimeInterval
    public var frontmostBundleId: String?

    public init(
        screenLocked: Bool = false,
        displayAsleep: Bool = false,
        idleSeconds: TimeInterval = 0,
        frontmostBundleId: String? = nil
    ) {
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.idleSeconds = idleSeconds
        self.frontmostBundleId = frontmostBundleId
    }
}

public enum AwayDecision {
    public enum Reason: String, Equatable, Sendable {
        case screenLocked
        case displayAsleep
        case idle
        case notFrontmost
    }

    /// Why the user counts as away, or nil when they're at the desk.
    ///
    /// `hostBundleId` is the app the Claude Code session runs in (the hook
    /// reads it from its environment). When it's unknown — an older hook, a
    /// terminal that doesn't set it — the frontmost signal can't say
    /// anything, so it never makes the user "away" on its own.
    public static func reason(
        signals: AwaySignals, policy: AwayPolicy, hostBundleId: String?
    ) -> Reason? {
        if policy.whenLocked {
            if signals.screenLocked { return .screenLocked }
            if signals.displayAsleep { return .displayAsleep }
        }
        if policy.whenIdle {
            let minutes = min(max(policy.idleMinutes, AwayPolicy.idleMinutesRange.lowerBound),
                              AwayPolicy.idleMinutesRange.upperBound)
            if signals.idleSeconds >= Double(minutes * 60) { return .idle }
        }
        if policy.whenNotFrontmost,
           let host = hostBundleId, !host.isEmpty,
           let front = signals.frontmostBundleId,
           front != host {
            return .notFrontmost
        }
        return nil
    }

    public static func isAway(signals: AwaySignals, policy: AwayPolicy, hostBundleId: String?) -> Bool {
        reason(signals: signals, policy: policy, hostBundleId: hostBundleId) != nil
    }
}

/// Reads `AwaySignals` from the live system.
public enum AwayProbe {
    @MainActor
    public static func current() -> AwaySignals {
        AwaySignals(
            screenLocked: screenLocked(),
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            idleSeconds: idleSeconds(),
            frontmostBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
    }

    /// The login window's lock flag. Absent from the session dictionary
    /// when the screen is unlocked.
    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Seconds since the last real input event. `.hidSystemState` counts
    /// hardware only, so Myna's own synthetic ⌘C never resets it.
    static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType is ~0; the imported enum accepts it.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}

/// "Is another app using the microphone?" — the call hold.
///
/// The primary signal is `kAudioDevicePropertyDeviceIsRunningSomewhere` on
/// the default input device. That flag is device-wide, though: a USB or
/// Bluetooth headset is one device with both input and output, so Myna's
/// own speech would make it "running" and hold Myna forever. When the
/// default input is also the default output, fall back to the per-process
/// `kAudioProcessPropertyIsRunningInput` (macOS 14.2+), skipping Myna itself.
/// Dictation apps record from the microphone too, so they trigger this.
public enum MicrophoneUse {
    public static func otherAppIsRecording() -> Bool {
        let input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        return decide(
            inputDevice: input,
            outputDevice: output,
            deviceRunning: { input.map(deviceIsRunningSomewhere) ?? false },
            otherProcessRecording: otherProcessIsRecording
        )
    }

    /// Pure choice between the two signals; see the type comment.
    static func decide(
        inputDevice: AudioObjectID?,
        outputDevice: AudioObjectID?,
        deviceRunning: () -> Bool,
        otherProcessRecording: () -> Bool?
    ) -> Bool {
        guard let input = inputDevice else { return false }
        if input == outputDevice {
            return otherProcessRecording() ?? false
        }
        return deviceRunning()
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func deviceIsRunningSomewhere(_ device: AudioObjectID) -> Bool {
        uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    /// nil when this macOS can't answer (before 14.2).
    private static func otherProcessIsRecording() -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else {
            return nil
        }
        let ownPid = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            guard uint32Property(process, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid)
            if status == noErr, pid == ownPid { continue }
            return true
        }
        return false
    }

    private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
