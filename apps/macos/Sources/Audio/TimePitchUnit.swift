// TimePitchUnit.swift — thin facade over AVAudioUnitTimePitch.
//
// We only ever change rate (speed) — pitch stays at 0 to avoid the
// chipmunk-voice effect. Apple Books and Overcast use this same phase
// vocoder approach. Rate is clamped to [0.5, 2.0] to bound the
// vocoder's audible artifacts.
import AVFoundation

public final class TimePitchUnit: @unchecked Sendable {
    public static let minRate: Float = 0.5
    public static let maxRate: Float = 2.0

    public let underlyingUnit: AVAudioUnitTimePitch

    public init() {
        self.underlyingUnit = AVAudioUnitTimePitch()
        self.underlyingUnit.pitch = 0
        self.underlyingUnit.rate = 1.0
    }

    public var rate: Float {
        get { underlyingUnit.rate }
        set { underlyingUnit.rate = Self.clamp(newValue) }
    }

    /// Pitch is intentionally unmodifiable — Myna only changes rate.
    public var pitch: Float { underlyingUnit.pitch }

    public static func clamp(_ rate: Float) -> Float {
        max(minRate, min(maxRate, rate))
    }
}
