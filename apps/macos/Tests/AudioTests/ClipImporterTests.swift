// ClipImporterTests.swift — any audio file in, the daemon's clip format out:
// mono 16-bit 24 kHz PCM WAV, 6–20 seconds.
import AVFoundation
import XCTest

@testable import Myna

final class ClipImporterTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    /// A stereo 44.1 kHz float file with a tone (or silence), as a phone
    /// voice memo or a downloaded clip might be.
    private func makeFile(seconds: Double, silent: Bool = false, ext: String = "caf") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-importer-\(UUID().uuidString).\(ext)")
        tempFiles.append(url)
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            // swiftlint:disable:next force_unwrapping
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                samples[index] = silent ? 0 : Float(sin(Double(index) * 2 * .pi * 220 / 44_100) * 0.3)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    func test_converts_to_mono_16_bit_24khz_wav() throws {
        let clip = try ClipImporter.clip(from: makeFile(seconds: 8))
        let wav = clip.wav
        XCTAssertEqual(String(bytes: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(bytes: wav.subdata(in: 8..<16), encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(readUInt16(wav, at: 20), 1, "PCM")
        XCTAssertEqual(readUInt16(wav, at: 22), 1, "mono")
        XCTAssertEqual(readUInt32(wav, at: 24), 24_000)
        XCTAssertEqual(readUInt16(wav, at: 34), 16)
        XCTAssertEqual(Int(readUInt32(wav, at: 40)), wav.count - 44)
        XCTAssertEqual(clip.seconds, 8, accuracy: 0.05)
        XCTAssertFalse(clip.trimmed)
    }

    func test_long_recordings_are_cut_to_twenty_seconds() throws {
        let clip = try ClipImporter.clip(from: makeFile(seconds: 31))
        XCTAssertEqual(clip.seconds, ClipImporter.maximumSeconds, accuracy: 0.05)
        XCTAssertTrue(clip.trimmed)
    }

    func test_short_recordings_are_refused() {
        XCTAssertThrowsError(try ClipImporter.clip(from: makeFile(seconds: 3))) { error in
            guard case ClipImporter.Failure.tooShort(let seconds) = error else {
                return XCTFail("expected tooShort, got \(error)")
            }
            XCTAssertEqual(seconds, 3, accuracy: 0.05)
        }
    }

    func test_silence_is_refused() {
        XCTAssertThrowsError(try ClipImporter.clip(from: makeFile(seconds: 8, silent: true))) { error in
            XCTAssertEqual(error as? ClipImporter.Failure, .silent)
        }
    }

    func test_non_audio_is_refused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-audio-\(UUID()).wav")
        tempFiles.append(url)
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try ClipImporter.clip(from: url)) { error in
            guard case ClipImporter.Failure.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }
}
