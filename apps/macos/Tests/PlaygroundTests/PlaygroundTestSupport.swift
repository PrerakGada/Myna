// PlaygroundTestSupport.swift — synthetic WAVs, temp directories and HTTP
// stubs for the Playground suites. Nothing here touches the real
// ~/Library/Application Support/Myna/playground or a real daemon.
import Foundation
import XCTest

@testable import Myna

enum PlaygroundFixtures {

    /// A mono or stereo 16-bit PCM WAV of the given samples.
    static func wav16(_ samples: [Int16], sampleRate: Int = 24_000, channels: Int = 1) -> Data {
        var body = Data()
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { body.append(contentsOf: $0) }
        }
        return wav(format: 1, bits: 16, sampleRate: sampleRate, channels: channels, body: body)
    }

    /// A 32-bit float WAV.
    static func wavFloat(_ samples: [Float], sampleRate: Int = 24_000) -> Data {
        var body = Data()
        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { body.append(contentsOf: $0) }
        }
        return wav(format: 3, bits: 32, sampleRate: sampleRate, channels: 1, body: body)
    }

    /// `seconds` of a sine at half scale, 16-bit mono.
    static func tone(seconds: Double, sampleRate: Int = 24_000) -> Data {
        let count = Int(seconds * Double(sampleRate))
        let samples = (0..<count).map { index in
            Int16(16_000 * sin(Double(index) * 2 * .pi * 220 / Double(sampleRate)))
        }
        return wav16(samples, sampleRate: sampleRate)
    }

    static func wav(
        format: UInt16,
        bits: UInt16,
        sampleRate: Int,
        channels: Int,
        body: Data,
        extraChunk: Data? = nil,
        declaredDataSize: UInt32? = nil
    ) -> Data {
        var fmt = Data()
        append(&fmt, format)
        append(&fmt, UInt16(channels))
        append(&fmt, UInt32(sampleRate))
        append(&fmt, UInt32(sampleRate * channels * Int(bits) / 8))
        append(&fmt, UInt16(channels * Int(bits) / 8))
        append(&fmt, bits)

        var riff = Data("WAVE".utf8)
        riff.append(Data("fmt ".utf8))
        append(&riff, UInt32(fmt.count))
        riff.append(fmt)
        if let extraChunk { riff.append(extraChunk) }
        riff.append(Data("data".utf8))
        append(&riff, declaredDataSize ?? UInt32(body.count))
        riff.append(body)

        var out = Data("RIFF".utf8)
        append(&out, UInt32(riff.count))
        out.append(riff)
        return out
    }

    static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func tempDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-playground-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    static func draft(
        text: String = "Hello there.",
        voice: String = "af_heart",
        groupId: String? = nil,
        audio: Data = PlaygroundFixtures.tone(seconds: 0.25)
    ) -> PlaygroundTakeStore.Draft {
        PlaygroundTakeStore.Draft(
            text: text,
            voice: voice,
            voiceLabel: "Heart",
            engine: "kokoro",
            speed: 1.0,
            renderMs: 120,
            reportedDuration: nil,
            groupId: groupId,
            audio: audio
        )
    }

    /// The body of a stubbed request. URLSession hands URLProtocol an
    /// upload body as a stream rather than `httpBody`.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// A stubbed reply to `request`.
    static func respond(
        _ request: URLRequest,
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data
    ) -> (HTTPURLResponse, Data) {
        // swiftlint:disable:next force_unwrapping
        (.make(url: request.url!, status: status, headers: headers), body)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func engineJSON(id: String, name: String, nativeSpeed: Bool) -> [String: Any] {
        [
            "id": id, "name": name, "maker": "m", "tagline": "t", "description": "d", "repo": "r",
            "params": "82M", "languages": ["English"], "license": "Apache 2.0", "credit": NSNull(),
            "badge": NSNull(), "download_mb": 300, "sample_rate": 24_000, "native_speed": nativeSpeed,
            "cloning": false, "voices": [["id": "af_heart", "label": "Heart"]], "default_voice": "af_heart",
            "stats": [
                "first_word_s": 0.1, "stream_first_s": NSNull(), "speed_x": 40.0,
                "peak_memory_mb": 3_000.0, "word_error_pct": 4.0, "measured_on": "M5",
            ],
            "active": true, "state": "installed", "progress": NSNull(), "downloaded_mb": NSNull(),
            "total_mb": NSNull(), "disk_mb": 372.0, "error": NSNull(),
        ]
    }

    static var voicesData: Data {
        json(voicesJSON)
    }

    private static var voicesJSON: [String: Any] {
        [
            "engine": "kokoro",
            "voices": [
                ["id": "af_heart", "label": "Heart", "lang": "en-us", "default": true],
                ["id": "af_bella", "label": "Bella", "lang": "en-us", "default": false],
                ["id": "am_adam", "label": "Adam", "lang": "en-us", "default": false],
            ],
        ]
    }
}

/// Waits for `condition` on the main actor, failing after `timeout`.
@MainActor
func playgroundWait(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
