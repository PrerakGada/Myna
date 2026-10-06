// ClipImporter.swift — turns any audio file into the clip a voice is copied from.
//
// Pocket TTS and Chatterbox copy a voice from a short recording. The daemon
// accepts only a PCM WAV of 5.5–30 s (Chatterbox refuses 5 s or less, and a
// long clip makes every Pocket read slower), and parses it with Python's
// stdlib `wave`, which reads nothing but integer PCM. So the app does the
// decoding: whatever AVFoundation can open (m4a, mp3, wav, aiff, caf) comes
// out as mono 16-bit 24 kHz, cut to the first 20 seconds.
import AVFoundation
import Foundation

public enum ClipImporter {
    public static let sampleRate: Double = 24_000
    /// Shortest usable clip. A little above the daemon's 5.5 s floor so a
    /// clip that just passes here never fails there after resampling.
    public static let minimumSeconds: Double = 6
    /// Longer clips are cut here: ten seconds or so of clear speech is what
    /// both engines were built around, and more only slows Pocket down.
    public static let maximumSeconds: Double = 20

    public enum Failure: Error, Equatable, LocalizedError {
        case unreadable(String)
        case tooShort(seconds: Double)
        case silent

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why):
                return "Myna couldn't read that file as audio (\(why))."
            case .tooShort(let seconds):
                return String(
                    format: "That recording is %.1f seconds. Use at least %.0f seconds of one person speaking.",
                    seconds, ClipImporter.minimumSeconds)
            case .silent:
                return "That recording is silent."
            }
        }
    }

    public struct Clip: Sendable, Equatable {
        public let wav: Data
        public let seconds: Double
        /// True when the file was longer than `maximumSeconds` and was cut.
        public let trimmed: Bool
    }

    /// Reads, downmixes, resamples and trims `url`. Blocking; call it off the
    /// main thread for anything longer than a voice memo.
    public static func clip(from url: URL) throws -> Clip {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let source = file.processingFormat
        let totalSeconds = Double(file.length) / source.sampleRate
        if totalSeconds < minimumSeconds {
            throw Failure.tooShort(seconds: totalSeconds)
        }
        let framesToRead = AVAudioFrameCount(min(Double(file.length), maximumSeconds * source.sampleRate))
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: framesToRead) else {
            throw Failure.unreadable("no buffer")
        }
        do {
            try file.read(into: input, frameCount: framesToRead)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let samples = try convert(input)
        if samples.allSatisfy({ $0 == 0 }) {
            throw Failure.silent
        }
        let seconds = Double(samples.count) / sampleRate
        return Clip(wav: wavData(samples), seconds: seconds, trimmed: totalSeconds > maximumSeconds + 0.05)
    }

    /// Mono Int16 at `sampleRate`.
    static func convert(_ input: AVAudioPCMBuffer) throws -> [Int16] {
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input.format, to: target)
        else {
            throw Failure.unreadable("unsupported audio format")
        }
        // Without this a stereo file keeps only its left channel.
        converter.downmix = true
        let ratio = sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure.unreadable("no buffer")
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw Failure.unreadable(conversionError?.localizedDescription ?? "conversion failed")
        }
        guard let channel = output.int16ChannelData?[0] else {
            throw Failure.unreadable("no samples")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// A canonical 44-byte-header PCM WAV.
    static func wavData(_ samples: [Int16]) -> Data {
        let rate = UInt32(sampleRate)
        let dataBytes = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))        // fmt chunk size
        append(UInt16(1))         // PCM
        append(UInt16(1))         // mono
        append(rate)
        append(rate * 2)          // byte rate
        append(UInt16(2))         // block align
        append(UInt16(16))        // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(dataBytes)
        // WAV samples are little-endian, as is every Mac Myna runs on.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
