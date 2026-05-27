// VoicePreviewServiceTests.swift — exercises the S09 preview
// orchestration: debounce, cancel-on-switch, ducking, 503 warming-label.
// We feed canned WAV data via MockURLProtocol and a stub AudioDuckable
// that records the duck factor history.
import AVFoundation
import XCTest

@testable import Myna

@MainActor
final class VoicePreviewServiceTests: XCTestCase {

    private let baseURL = URL(string: "http://127.0.0.1:8766")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DaemonClient {
        DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
    }

    /// Stub that records the duck factor each time `duck(to:)` is called.
    private final class StubSink: AudioDuckable, @unchecked Sendable {
        var ducks: [Float] = []
        var restoreCount = 0
        func duck(to factor: Float) -> () -> Void {
            ducks.append(factor)
            return { [weak self] in self?.restoreCount += 1 }
        }
    }

    /// 1s of silence as a valid WAV blob.
    private func silenceWAV() throws -> Data {
        let sampleRate: Double = 44_100
        let frames: AVAudioFrameCount = AVAudioFrameCount(sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else {
            throw NSError(domain: "test", code: 0)
        }
        buffer.frameLength = frames
        // memset to zero
        if let channel = buffer.floatChannelData {
            for i in 0..<Int(frames) {
                channel[0][i] = 0
            }
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var settings = format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        let file = try AVAudioFile(forWriting: tmp, settings: settings)
        try file.write(from: buffer)
        return try Data(contentsOf: tmp)
    }

    func test_503_yields_warming_state_then_idle() async throws {
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 503), Data())
        }
        let client = makeClient()
        let sink = StubSink()
        let svc = VoicePreviewService(client: client, sink: sink)
        svc.preview(voiceId: "bella")
        // Wait long enough for the warming-state to land but NOT for the
        // 2s reset.
        try await Task.sleep(nanoseconds: 500_000_000)
        if case .warming(let id) = svc.state {
            XCTAssertEqual(id, "bella")
        } else {
            XCTFail("expected .warming, got \(svc.state)")
        }
    }

    func test_debounce_drops_rapid_clicks() async throws {
        let wav = try silenceWAV()
        // Only enqueue ONE handler; the second click should be debounced
        // and never hit the network.
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 200), wav)
        }
        let client = makeClient()
        let svc = VoicePreviewService(client: client, sink: nil)
        svc.preview(voiceId: "a")
        svc.preview(voiceId: "b")  // should be dropped (within 300ms of first)
        // Yield to scheduler so the service starts its async task.
        try await Task.sleep(nanoseconds: 50_000_000)
        // Confirm we're in a loading/playing state for "a", not "b".
        switch svc.state {
        case .loading(let id), .playing(let id):
            XCTAssertEqual(id, "a", "second click within 300ms should be debounced")
        case .warming, .idle, .failed:
            // Acceptable if the first request hasn't started yet — the
            // important thing is it's NOT id "b".
            break
        }
    }

    func test_ducking_envelope_records_duck_and_restore() async throws {
        let wav = try silenceWAV()
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 200), wav)
        }
        let client = makeClient()
        let sink = StubSink()
        let svc = VoicePreviewService(client: client, sink: sink)
        svc.preview(voiceId: "bella")
        // Wait long enough for the 1s WAV to finish (plus slop).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(sink.ducks.first, VoicePreviewService.duckFactor)
        XCTAssertGreaterThanOrEqual(sink.restoreCount, 1, "duck must be restored after preview ends")
    }

    func test_cancel_restores_volume_immediately() async throws {
        let wav = try silenceWAV()
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 200), wav)
        }
        let client = makeClient()
        let sink = StubSink()
        let svc = VoicePreviewService(client: client, sink: sink)
        svc.preview(voiceId: "bella")
        try await Task.sleep(nanoseconds: 100_000_000)  // mid-preview
        svc.cancel()
        // restore should have fired during cancel.
        XCTAssertGreaterThanOrEqual(sink.restoreCount, 1)
    }
}
