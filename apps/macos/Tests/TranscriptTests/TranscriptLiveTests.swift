// TranscriptLiveTests.swift — a real /v2/synthesize stream through the app's
// client and parser into a Transcript. Plays nothing.
//
// Skipped unless a daemon is named:
//
//   TEST_RUNNER_MYNA_TRANSCRIPT_LIVE_URL=http://127.0.0.1:8805 xcodebuild test … \
//     -only-testing:MynaTests/TranscriptLiveTests
import AVFoundation
import XCTest

@testable import Myna

final class TranscriptLiveTests: XCTestCase {
    func testLiveStreamBuildsTheSpokenTranscript() async throws {
        guard let base = ProcessInfo.processInfo.environment["MYNA_TRANSCRIPT_LIVE_URL"],
              let url = URL(string: base) else {
            throw XCTSkip("set TEST_RUNNER_MYNA_TRANSCRIPT_LIVE_URL to a daemon to run")
        }
        let text = "Dr. Smith opened the door. Behind it was a long corridor, lit by a row of lamps that "
            + "flickered as the wind came through the broken windows on the left side, and at the far end "
            + "a single chair stood waiting, e.g. for a visitor who never came. Nobody moved. It cost 3.5 "
            + "dollars to get in! Was it worth it? \u{201C}Perhaps,\u{201D} she said."
        let client = DaemonClient(baseURL: url)
        // 500 is what seamless mode asks for (AppDispatcher.seamlessChunkChars).
        let request = SynthesizeRequest(text: text, speed: 1.0, mode: .full, chunkChars: 500)

        var chunks: [SynthesizedChunk] = []
        var durations: [TimeInterval] = []
        for try await chunk in client.synthesize(request) {
            chunks.append(chunk)
            durations.append(try Self.duration(of: chunk.wavData))
        }
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "the short first chunk and the rest")
        XCTAssertTrue(chunks.allSatisfy { $0.fullText != nil }, "this daemon sends X-Chunk-Text-Full")
        XCTAssertTrue(chunks.contains { ($0.fullText?.count ?? 0) > $0.textPreview.count }, "some chunk beyond 200")

        var transcript = Transcript(readID: UUID(), title: "live", source: .selection)
        for (chunk, duration) in zip(chunks, durations) {
            XCTAssertGreaterThan(duration, 0)
            transcript.appendChunk(text: chunk.spokenText, duration: duration, isPreviewOnly: chunk.fullText == nil)
        }
        let spoken = transcript.sentences.map(\.text).joined(separator: " ")
        XCTAssertEqual(spoken.filter { !$0.isWhitespace }, text.filter { !$0.isWhitespace }, "every word, once")
        XCTAssertEqual(transcript.sentences.first?.text, "Dr. Smith opened the door.")
        XCTAssertEqual(transcript.audioDuration, durations.reduce(0, +), accuracy: 1e-9)
        let starts = transcript.sentences.compactMap { $0.anchor?.start }
        XCTAssertEqual(zip(starts, starts.dropFirst()).filter { $0 > $1 }.count, 0, "starts never go backwards")
        print("live transcript:", transcript.sentences.map { String(format: "%.2f %@", $0.anchor?.start ?? -1, $0.text) })
    }

    private static func duration(of wav: Data) throws -> TimeInterval {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-live-\(UUID()).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
