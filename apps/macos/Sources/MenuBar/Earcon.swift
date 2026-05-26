// Earcon.swift — optional short tones for non-speech feedback:
//   - thinkingOnset: 80ms, 220Hz sine, -18dB (per Sally's spec § 4)
//   - toastReady: 60ms, 220Hz sine, -20dB (per Sally's spec § 5)
//
// Sounds are synthesised in-memory on first use and cached. We DO NOT
// route through AudioPlayer (which is reserved for TTS playback) — earcons
// use a separate one-shot AVAudioPlayer to avoid blocking the main
// playback graph.
//
// Earcons NEVER overlap speech: callers gate on `state != .speaking`
// before calling `play(_:)`.
import AVFoundation

@MainActor
public final class Earcon {
    public static let shared = Earcon()

    public enum Tone: String, Sendable {
        case thinkingOnset
        case toastReady
        case errorTwoTone

        var durationMs: Int {
            switch self {
            case .thinkingOnset: return 80
            case .toastReady: return 60
            case .errorTwoTone: return 120
            }
        }

        var attenuationDb: Double {
            switch self {
            case .thinkingOnset: return -18
            case .toastReady: return -20
            case .errorTwoTone: return -22
            }
        }

        /// Fundamental frequency. errorTwoTone uses two — first descends
        /// to the second over the duration.
        var freqHz: (Double, Double) {
            switch self {
            case .thinkingOnset: return (220, 220)
            case .toastReady: return (220, 220)
            case .errorTwoTone: return (440, 330)
            }
        }
    }

    private var cache: [Tone: AVAudioPlayer] = [:]

    public init() {}

    /// Play the given tone. Silently no-ops if audio session setup fails.
    public func play(_ tone: Tone) {
        let player: AVAudioPlayer
        if let cached = cache[tone] {
            player = cached
        } else {
            guard let new = makePlayer(for: tone) else { return }
            cache[tone] = new
            player = new
        }
        player.currentTime = 0
        player.play()
    }

    private func makePlayer(for tone: Tone) -> AVAudioPlayer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myna-earcon-\(tone.rawValue).caf")
        guard renderToFile(tone: tone, url: url) else { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    /// Render a CAF file at `url` containing the synthesized sine.
    /// Returns true on success.
    private func renderToFile(tone: Tone, url: URL) -> Bool {
        let sampleRate: Double = 44_100
        let frameCount = AVAudioFrameCount(Double(tone.durationMs) / 1000.0 * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return false }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return false }
        let attenuation = pow(10.0, tone.attenuationDb / 20.0)
        let (startHz, endHz) = tone.freqHz
        let total = Double(frameCount)
        // 5ms cosine ramp at start and end to avoid clicks.
        let rampSamples = min(Int(0.005 * sampleRate), Int(frameCount / 4))
        var phase: Double = 0
        for idx in 0..<Int(frameCount) {
            let progress = Double(idx) / total
            let hz = startHz + (endHz - startHz) * progress
            let increment = 2.0 * .pi * hz / sampleRate
            var sample = sin(phase) * attenuation
            // Linear-cosine envelope on the ends.
            if idx < rampSamples {
                let ratio = Double(idx) / Double(rampSamples)
                sample *= (1 - cos(ratio * .pi)) / 2
            } else if idx > Int(frameCount) - rampSamples {
                let ratio = Double(Int(frameCount) - idx) / Double(rampSamples)
                sample *= (1 - cos(ratio * .pi)) / 2
            }
            channel[idx] = Float(sample)
            phase += increment
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }
}
