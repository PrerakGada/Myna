// PlaygroundAudio.swift — reads a take's WAV well enough to draw it:
// the format header, the duration, and a strip of peak levels.
//
// Why parse RIFF by hand instead of AVAudioFile: the take arrives as bytes
// in memory, the waveform is computed once off the main actor when the
// take is stored, and a pure function over `Data` can be tested with
// synthetic WAVs. Only the formats the engines produce matter (16-bit and
// float PCM), but 24/32-bit integer PCM and WAVE_FORMAT_EXTENSIBLE cost a
// few lines each, so they are handled too.
import Foundation

enum PlaygroundWAV {

    struct Info: Equatable, Sendable {
        let sampleRate: Int
        let channels: Int
        let bitsPerSample: Int
        let isFloat: Bool
        /// Byte offset of the first sample, and how many sample bytes follow.
        let dataOffset: Int
        let dataLength: Int

        var bytesPerFrame: Int { channels * bitsPerSample / 8 }
        var frameCount: Int { bytesPerFrame > 0 ? dataLength / bytesPerFrame : 0 }
        var duration: Double { sampleRate > 0 ? Double(frameCount) / Double(sampleRate) : 0 }
    }

    /// Stored peaks per take. The view resamples to whatever fits.
    static let storedBarCount = 240

    /// Parses the RIFF header. Tolerates the placeholder data sizes that
    /// streaming writers leave behind (0 or 0xFFFFFFFF) by taking the rest
    /// of the buffer.
    static func parse(_ data: Data) -> Info? {
        data.withUnsafeBytes { raw -> Info? in
            guard raw.count >= 12,
                  fourCC(raw, 0) == "RIFF",
                  fourCC(raw, 8) == "WAVE"
            else { return nil }

            var format: Format?
            var offset = 12
            while offset + 8 <= raw.count {
                let chunkID = fourCC(raw, offset)
                let declared = Int(raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self).littleEndian)
                let body = offset + 8
                if chunkID == "fmt ", body + 16 <= raw.count {
                    var tag = raw.loadUnaligned(fromByteOffset: body, as: UInt16.self).littleEndian
                    let channels = Int(raw.loadUnaligned(fromByteOffset: body + 2, as: UInt16.self).littleEndian)
                    let rate = Int(raw.loadUnaligned(fromByteOffset: body + 4, as: UInt32.self).littleEndian)
                    let bits = Int(raw.loadUnaligned(fromByteOffset: body + 14, as: UInt16.self).littleEndian)
                    // WAVE_FORMAT_EXTENSIBLE: the real tag opens the sub-format GUID.
                    if tag == 0xFFFE, declared >= 40, body + 26 <= raw.count {
                        tag = raw.loadUnaligned(fromByteOffset: body + 24, as: UInt16.self).littleEndian
                    }
                    format = Format(tag: tag, channels: channels, rate: rate, bits: bits)
                } else if chunkID == "data" {
                    guard let format else { return nil }
                    let available = raw.count - body
                    let length = (declared == 0 || declared == 0xFFFF_FFFF || declared > available)
                        ? available : declared
                    return makeInfo(format: format, dataOffset: body, dataLength: length)
                }
                // Chunks are word-aligned: an odd size carries a pad byte.
                offset = body + declared + (declared & 1)
            }
            return nil
        }
    }

    /// The `fmt ` chunk, as far as drawing a waveform cares.
    private struct Format {
        let tag: UInt16
        let channels: Int
        let rate: Int
        let bits: Int
    }

    private static func makeInfo(
        format: Format,
        dataOffset: Int,
        dataLength: Int
    ) -> Info? {
        let isFloat: Bool
        switch (format.tag, format.bits) {
        case (1, 8), (1, 16), (1, 24), (1, 32): isFloat = false
        case (3, 32), (3, 64): isFloat = true
        default: return nil
        }
        guard format.channels > 0, format.rate > 0 else { return nil }
        return Info(
            sampleRate: format.rate,
            channels: format.channels,
            bitsPerSample: format.bits,
            isFloat: isFloat,
            dataOffset: dataOffset,
            dataLength: dataLength
        )
    }

    private static func fourCC(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> String {
        String(bytes: raw[offset..<offset + 4], encoding: .ascii) ?? ""
    }

    /// Peak level per bar, normalised so the loudest bar is 1. A quiet
    /// take still reads as a shape rather than a flat line.
    ///
    /// Long takes are sampled rather than read in full: at most
    /// `framesPerBarLimit` frames are inspected per bar, which keeps a
    /// 40,000-character take (tens of millions of samples) cheap while
    /// still drawing a faithful outline.
    static func peaks(_ data: Data, bars: Int = storedBarCount, framesPerBarLimit: Int = 2_048) -> [Float] {
        guard bars > 0, let info = parse(data), info.frameCount > 0 else { return [] }
        let frames = info.frameCount
        let bytesPerSample = info.bitsPerSample / 8
        var levels = [Float](repeating: 0, count: bars)
        data.withUnsafeBytes { raw in
            for bar in 0..<bars {
                let start = frames * bar / bars
                let end = max(start + 1, frames * (bar + 1) / bars)
                let stride = max(1, (end - start) / framesPerBarLimit)
                var peak: Float = 0
                var frame = start
                while frame < min(end, frames) {
                    let base = info.dataOffset + frame * info.bytesPerFrame
                    for channel in 0..<info.channels {
                        let value = abs(sample(raw, at: base + channel * bytesPerSample, info: info))
                        if value > peak { peak = value }
                    }
                    frame += stride
                }
                levels[bar] = peak
            }
        }
        let loudest = levels.max() ?? 0
        guard loudest > 0 else { return levels }
        return levels.map { min(1, $0 / loudest) }
    }

    private static func sample(_ raw: UnsafeRawBufferPointer, at offset: Int, info: Info) -> Float {
        switch (info.isFloat, info.bitsPerSample) {
        case (true, 32):
            return Float(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
        case (true, 64):
            return Float(Double(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian))
        case (false, 8):
            // 8-bit WAV is unsigned, centred on 128.
            return (Float(raw[offset]) - 128) / 128
        case (false, 16):
            return Float(Int16(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian)) / 32_768
        case (false, 24):
            let value = Int32(raw[offset]) | Int32(raw[offset + 1]) << 8 | Int32(Int8(bitPattern: raw[offset + 2])) << 16
            return Float(value) / 8_388_608
        case (false, 32):
            return Float(Int32(bitPattern: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian))
                / 2_147_483_648
        default:
            return 0
        }
    }
}

enum PlaygroundWaveformMath {

    /// Fits `peaks` into `count` bars, keeping the loudest value of each
    /// group so short transients survive the squeeze. With room to spare
    /// it returns the peaks unchanged; the view just draws them wider.
    static func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        guard count < peaks.count else { return peaks }
        return (0..<count).map { index in
            let start = peaks.count * index / count
            let end = max(start + 1, peaks.count * (index + 1) / count)
            return peaks[start..<min(end, peaks.count)].max() ?? 0
        }
    }

    /// Peaks survive the JSON index as bytes: 240 of them per take.
    static func quantize(_ peaks: [Float]) -> [UInt8] {
        peaks.map { UInt8((max(0, min(1, $0)) * 255).rounded()) }
    }

    static func dequantize(_ bars: [UInt8]) -> [Float] {
        bars.map { Float($0) / 255 }
    }

    /// Where a click at `x` in a strip `width` wide lands, 0…1.
    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(max(0, min(1, x / width)))
    }
}
