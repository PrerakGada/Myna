// PlaygroundAudioTests.swift — WAV header parsing and waveform peaks,
// against WAVs built byte by byte.
import XCTest

@testable import Myna

final class PlaygroundAudioTests: XCTestCase {

    // MARK: - parse

    func testParses16BitMono() throws {
        let wav = PlaygroundFixtures.wav16([Int16](repeating: 0, count: 24_000), sampleRate: 24_000)
        let info = try XCTUnwrap(PlaygroundWAV.parse(wav))
        XCTAssertEqual(info.sampleRate, 24_000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.bitsPerSample, 16)
        XCTAssertFalse(info.isFloat)
        XCTAssertEqual(info.dataOffset, 44)
        XCTAssertEqual(info.frameCount, 24_000)
        XCTAssertEqual(info.duration, 1.0, accuracy: 1e-9)
    }

    func testParsesStereoFrameCount() throws {
        let wav = PlaygroundFixtures.wav16([Int16](repeating: 0, count: 480), sampleRate: 48_000, channels: 2)
        let info = try XCTUnwrap(PlaygroundWAV.parse(wav))
        XCTAssertEqual(info.frameCount, 240)
        XCTAssertEqual(info.duration, 0.005, accuracy: 1e-9)
    }

    func testParsesFloat32() throws {
        let info = try XCTUnwrap(PlaygroundWAV.parse(PlaygroundFixtures.wavFloat([0, 0.5, -0.5, 0])))
        XCTAssertTrue(info.isFloat)
        XCTAssertEqual(info.bitsPerSample, 32)
        XCTAssertEqual(info.frameCount, 4)
    }

    func testSkipsChunksBeforeDataIncludingOddPadding() throws {
        // A 3-byte LIST chunk carries one pad byte.
        var list = Data("LIST".utf8)
        PlaygroundFixtures.append(&list, UInt32(3))
        list.append(contentsOf: [1, 2, 3, 0])
        let body = Data(repeating: 0, count: 8)
        let wav = PlaygroundFixtures.wav(format: 1, bits: 16, sampleRate: 16_000, channels: 1, body: body, extraChunk: list)
        let info = try XCTUnwrap(PlaygroundWAV.parse(wav))
        XCTAssertEqual(info.frameCount, 4)
        XCTAssertEqual(info.dataOffset, 44 + list.count)
    }

    func testStreamingPlaceholderDataSizeUsesRestOfFile() throws {
        let body = Data(repeating: 0, count: 200)
        for placeholder: UInt32 in [0, 0xFFFF_FFFF] {
            let wav = PlaygroundFixtures.wav(
                format: 1, bits: 16, sampleRate: 24_000, channels: 1, body: body, declaredDataSize: placeholder)
            XCTAssertEqual(PlaygroundWAV.parse(wav)?.frameCount, 100)
        }
    }

    func testExtensibleFormatReadsSubformat() throws {
        // WAVE_FORMAT_EXTENSIBLE with a PCM sub-format GUID.
        var fmt = Data()
        PlaygroundFixtures.append(&fmt, UInt16(0xFFFE))
        PlaygroundFixtures.append(&fmt, UInt16(1))
        PlaygroundFixtures.append(&fmt, UInt32(24_000))
        PlaygroundFixtures.append(&fmt, UInt32(48_000))
        PlaygroundFixtures.append(&fmt, UInt16(2))
        PlaygroundFixtures.append(&fmt, UInt16(16))
        PlaygroundFixtures.append(&fmt, UInt16(22))  // cbSize
        PlaygroundFixtures.append(&fmt, UInt16(16))  // valid bits
        PlaygroundFixtures.append(&fmt, UInt32(4))   // channel mask
        PlaygroundFixtures.append(&fmt, UInt16(1))   // sub-format: PCM
        fmt.append(Data(repeating: 0, count: 14))
        var riff = Data("WAVEfmt ".utf8)
        PlaygroundFixtures.append(&riff, UInt32(fmt.count))
        riff.append(fmt)
        riff.append(Data("data".utf8))
        PlaygroundFixtures.append(&riff, UInt32(8))
        riff.append(Data(repeating: 0, count: 8))
        var wav = Data("RIFF".utf8)
        PlaygroundFixtures.append(&wav, UInt32(riff.count))
        wav.append(riff)

        let info = try XCTUnwrap(PlaygroundWAV.parse(wav))
        XCTAssertFalse(info.isFloat)
        XCTAssertEqual(info.frameCount, 4)
    }

    func testRejectsNonWAV() {
        XCTAssertNil(PlaygroundWAV.parse(Data()))
        XCTAssertNil(PlaygroundWAV.parse(Data("ID3 not a wav at all".utf8)))
        // Unsupported encoding (A-law).
        XCTAssertNil(PlaygroundWAV.parse(PlaygroundFixtures.wav(
            format: 6, bits: 8, sampleRate: 8_000, channels: 1, body: Data(repeating: 0, count: 4))))
    }

    // MARK: - peaks

    func testPeaksFollowTheSignalAndNormalise() {
        // Quiet first half, loud second half.
        let samples = [Int16](repeating: 1_000, count: 100) + [Int16](repeating: -8_000, count: 100)
        let peaks = PlaygroundWAV.peaks(PlaygroundFixtures.wav16(samples), bars: 4)
        XCTAssertEqual(peaks.count, 4)
        XCTAssertEqual(peaks[0], 0.125, accuracy: 0.001)
        XCTAssertEqual(peaks[1], 0.125, accuracy: 0.001)
        XCTAssertEqual(peaks[2], 1, accuracy: 0.001)
        XCTAssertEqual(peaks[3], 1, accuracy: 0.001)
    }

    func testPeaksOfFloatAudio() {
        let peaks = PlaygroundWAV.peaks(PlaygroundFixtures.wavFloat([0.1, 0.1, -0.4, 0.4]), bars: 2)
        XCTAssertEqual(peaks[0], 0.25, accuracy: 0.001)
        XCTAssertEqual(peaks[1], 1, accuracy: 0.001)
    }

    func testSilenceIsFlatNotNaN() {
        let peaks = PlaygroundWAV.peaks(PlaygroundFixtures.wav16([Int16](repeating: 0, count: 64)), bars: 8)
        XCTAssertEqual(peaks, [Float](repeating: 0, count: 8))
    }

    func testMoreBarsThanFramesStillFillsEveryBar() {
        let peaks = PlaygroundWAV.peaks(PlaygroundFixtures.wav16([100, -200, 300]), bars: 6)
        XCTAssertEqual(peaks.count, 6)
        XCTAssertEqual(peaks.max() ?? 0, 1, accuracy: 0.001)
    }

    func testLongAudioIsSampledNotMissed() {
        // One loud spike per bar survives sampling when the stride lands on it;
        // what matters is that a long take produces a full strip quickly.
        let tone = PlaygroundFixtures.tone(seconds: 20)
        let start = Date()
        let peaks = PlaygroundWAV.peaks(tone)
        XCTAssertEqual(peaks.count, PlaygroundWAV.storedBarCount)
        XCTAssertTrue(peaks.allSatisfy { $0 > 0.5 }, "a steady tone is loud in every bar")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testPeaksOfGarbageAreEmpty() {
        XCTAssertEqual(PlaygroundWAV.peaks(Data("nope".utf8)), [])
    }

    // MARK: - waveform maths

    func testResampleKeepsLoudestOfEachGroup() {
        let peaks: [Float] = [0.1, 0.9, 0.2, 0.3, 0.8, 0.1]
        XCTAssertEqual(PlaygroundWaveformMath.resample(peaks, to: 3), [0.9, 0.3, 0.8])
        XCTAssertEqual(PlaygroundWaveformMath.resample(peaks, to: 2), [0.9, 0.8])
        XCTAssertEqual(PlaygroundWaveformMath.resample(peaks, to: 1), [0.9])
    }

    func testResampleWithRoomToSpareReturnsPeaks() {
        let peaks: [Float] = [0.1, 0.5]
        XCTAssertEqual(PlaygroundWaveformMath.resample(peaks, to: 10), peaks)
        XCTAssertEqual(PlaygroundWaveformMath.resample([], to: 10), [])
        XCTAssertEqual(PlaygroundWaveformMath.resample(peaks, to: 0), [])
    }

    func testQuantizeRoundTrip() {
        let bytes = PlaygroundWaveformMath.quantize([0, 0.5, 1, 1.4, -0.2])
        XCTAssertEqual(bytes, [0, 128, 255, 255, 0])
        let back = PlaygroundWaveformMath.dequantize(bytes)
        XCTAssertEqual(back[1], 128.0 / 255.0, accuracy: 1e-6)
    }

    func testSeekFractionClamps() {
        XCTAssertEqual(PlaygroundWaveformMath.fraction(x: 50, width: 200), 0.25)
        XCTAssertEqual(PlaygroundWaveformMath.fraction(x: -10, width: 200), 0)
        XCTAssertEqual(PlaygroundWaveformMath.fraction(x: 500, width: 200), 1)
        XCTAssertEqual(PlaygroundWaveformMath.fraction(x: 10, width: 0), 0)
    }
}
