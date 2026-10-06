// PlaygroundLiveTests.swift — the Playground against a real daemon.
//
// Skipped unless a port is given, so CI and a plain test run never touch a
// daemon:
//
//   TEST_RUNNER_MYNA_PLAYGROUND_LIVE_PORT=8793 xcodebuild test … \
//     -only-testing:MynaTests/PlaygroundLiveTests
//
// (xcodebuild hands TEST_RUNNER_-prefixed variables to the test process
// without the prefix.) Point it at a dev daemon started from a worktree,
// never at the user's own on 8766. It renders two short sentences with
// whatever engine is active; it never switches engines.
import XCTest

@testable import Myna

@MainActor
final class PlaygroundLiveTests: XCTestCase {

    private var directory: URL!
    private var baseURL: URL!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        guard let port = ProcessInfo.processInfo.environment["MYNA_PLAYGROUND_LIVE_PORT"],
              port != "8766",
              let url = URL(string: "http://127.0.0.1:\(port)")
        else { throw XCTSkip("set TEST_RUNNER_MYNA_PLAYGROUND_LIVE_PORT to a dev daemon's port") }
        baseURL = url
        directory = PlaygroundFixtures.tempDirectory("live")
        suiteName = "playground-live-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeModel() throws -> PlaygroundModel {
        let model = PlaygroundModel(
            client: DaemonClient(baseURL: baseURL),
            render: RenderClient(baseURL: baseURL),
            store: PlaygroundTakeStore(directory: directory),
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            preferredVoice: { nil }
        )
        model.playWhenReady = false
        return model
    }

    func testGenerateSaveAndPlayAgainstTheRealDaemon() async throws {
        let model = try makeModel()
        await model.refresh()
        XCTAssertEqual(model.engineState, .ready)
        let engine = try XCTUnwrap(model.engine)
        XCTAssertFalse(model.voices.isEmpty)
        XCTAssertFalse(model.voiceId.isEmpty)
        XCTAssertTrue(model.formats.contains { $0.id == "wav" })
        XCTAssertFalse(model.formats.contains { $0.id == "pcm" })
        print("live: engine \(engine.id), native speed \(engine.nativeSpeed), \(model.voices.count) voice(s)")

        model.draft.text = "The playground renders this sentence once."
        model.speed = 1.3
        model.generate()
        await playgroundWait(timeout: 120) { model.job == nil }
        XCTAssertNil(model.notice, model.notice?.message ?? "")

        let take = try XCTUnwrap(model.store.takes.first)
        XCTAssertEqual(take.engine, engine.id)
        XCTAssertEqual(take.voice, model.voiceId)
        XCTAssertEqual(take.speed, engine.nativeSpeed ? 1.3 : nil)
        XCTAssertGreaterThan(take.durationS, 0.5)
        XCTAssertNotNil(take.renderMs)
        XCTAssertGreaterThan(take.bars.max() ?? 0, 200, "the waveform has a loudest bar near full scale")
        XCTAssertGreaterThan(Set(take.bars).count, 10, "and a shape, not a flat line")

        let wav = try Data(contentsOf: model.audioURL(for: take))
        let info = try XCTUnwrap(PlaygroundWAV.parse(wav))
        XCTAssertEqual(info.duration, take.durationS, accuracy: 0.05, "header and X-Myna-Duration-S agree")
        print("live: take \(take.durationS)s, rendered in \(take.renderMs ?? -1) ms, \(info.sampleRate) Hz")

        // Save as: WAV is the same bytes; M4A and FLAC come from /v2/transcode.
        for id in ["wav", "m4a", "flac"] {
            guard let format = model.formats.first(where: { $0.id == id && $0.available }) else { continue }
            let out = directory.appendingPathComponent(model.fileName(for: take, ext: format.ext))
            try await PlaygroundExport.export(
                source: model.audioURL(for: take), as: format, to: out, using: RenderClient(baseURL: baseURL))
            let bytes = try Data(contentsOf: out)
            switch id {
            case "wav": XCTAssertEqual(bytes, wav)
            case "m4a": XCTAssertEqual(String(bytes: bytes[4..<8], encoding: .ascii), "ftyp")
            default: XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "fLaC")
            }
            print("live: saved \(out.lastPathComponent) (\(bytes.count) bytes)")
        }

        // The Playground's own player opens the take (loaded paused, no sound).
        model.seek(take, to: 0.5)
        XCTAssertEqual(model.player.currentId, take.id)
        XCTAssertNil(model.player.lastError)
        XCTAssertEqual(model.player.progress(for: take.id), 0.5, accuracy: 0.05)
        model.player.stop()

        // A readable file for drags and the pasteboard.
        let shareable = try XCTUnwrap(model.shareableFile(for: take))
        XCTAssertEqual(try Data(contentsOf: shareable), wav)
        try? FileManager.default.removeItem(at: shareable.deletingLastPathComponent())
    }

    func testCompareAgainstTheRealDaemon() async throws {
        let model = try makeModel()
        await model.refresh()
        model.draft.text = "Two voices, one sentence."
        for voice in model.voices.prefix(2) { model.toggleCompareVoice(voice.id) }
        guard model.voices.count >= 2 else {
            model.compare()
            XCTAssertNil(model.job, "a one-voice engine has nothing to compare")
            throw XCTSkip("the active engine has one voice; comparison needs two")
        }
        model.compare()
        await playgroundWait(timeout: 180) { model.job == nil }
        XCTAssertNil(model.notice, model.notice?.message ?? "")
        XCTAssertEqual(model.store.takes.count, 2)
        guard case .comparison(_, let takes) = PlaygroundTakeSection.sections(from: model.store.takes).first else {
            return XCTFail("expected one comparison")
        }
        XCTAssertEqual(takes.map(\.voice), Array(model.compareVoiceIds))
    }
}
