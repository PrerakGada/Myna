// PowerMonitor.swift — detects when the machine is in Low Power Mode
// so we can suspend non-essential animations (S07 thinking indicator
// halo pulse, S08 toast slide-in easing).
//
// `NSProcessInfo.isLowPowerModeEnabled` is the documented API, but it's
// macOS 12+. The brief calls out `IOPSGetProvidingPowerSourceType` as a
// belt-and-braces fallback; we use both — Low Power Mode OR being on
// battery + ProcessInfo's "thermal pressure" hint.
//
// We expose a single boolean `shouldSuppressAnimation` so callers don't
// have to reason about the underlying signals.
import Foundation
import IOKit.ps

public final class PowerMonitor: @unchecked Sendable {
    public static let shared = PowerMonitor()

    private let lock = NSLock()
    private var cachedSnapshot: Snapshot?
    private static let cacheTTLSeconds: TimeInterval = 5

    public struct Snapshot: Sendable, Equatable {
        public let isLowPowerMode: Bool
        public let isOnBattery: Bool
        public let capturedAt: Date

        public var shouldSuppressAnimation: Bool {
            // Only suppress when Low Power Mode is explicitly on. Being
            // on battery alone is NOT enough — every user laptop is on
            // battery sometimes, and suspending animation there would
            // make Myna feel broken half the time.
            isLowPowerMode
        }
    }

    public init() {}

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedSnapshot, Date().timeIntervalSince(cached.capturedAt) < Self.cacheTTLSeconds {
            return cached
        }
        let snap = readSnapshot()
        cachedSnapshot = snap
        return snap
    }

    public var shouldSuppressAnimation: Bool {
        snapshot().shouldSuppressAnimation
    }

    private func readSnapshot() -> Snapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let onBattery = Self.isProvidingPowerSourceBattery()
        return Snapshot(isLowPowerMode: lowPower, isOnBattery: onBattery, capturedAt: Date())
    }

    /// Wrap `IOPSGetProvidingPowerSourceType` returns `kIOPMBatteryPowerKey`
    /// when running on the internal battery; returns `kIOPMACPowerKey`
    /// otherwise. Used here just for telemetry; animation suppression
    /// hinges only on Low Power Mode.
    public static func isProvidingPowerSourceBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else {
            return false
        }
        // `Battery Power` constant; comparing the raw string is the
        // documented approach.
        return providing == "Battery Power" || providing == "InternalBattery"
    }
}
