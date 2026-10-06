// PlaygroundSnapshotTests.swift — draws the Playground offscreen to PNGs
// so its layout can be checked without opening the app.
//
// Skipped unless a folder is given:
//
//   TEST_RUNNER_MYNA_PLAYGROUND_SNAPSHOT_DIR=/tmp/shots xcodebuild test … \
//     -only-testing:MynaTests/PlaygroundSnapshotTests
//
// The views are the real ones, hosted in an NSHostingView inside a window
// that is never shown, fed by a model over a stubbed daemon. It asserts
// only that nothing is wider than the pane; the pictures are for a person.
import AppKit
import SwiftUI
import XCTest

@testable import Myna

@MainActor
final class PlaygroundSnapshotTests: XCTestCase {

    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8766")!
    private var output: URL!
    private var directory: URL!
    private var suiteName = ""

    /// Content column at the Dashboard's minimum and default window widths.
    private let minimumWidth = DashboardDesign.minWindowWidth - DashboardDesign.sidebarWidth - 1
    private let defaultWidth = DashboardDesign.windowWidth - DashboardDesign.sidebarWidth - 1

    override func setUp() async throws {
        // No super.setUp(): sending the XCTestCase across actors fails CI's Swift 6 (see PillSettingsTests).
        guard let path = ProcessInfo.processInfo.environment["MYNA_PLAYGROUND_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_MYNA_PLAYGROUND_SNAPSHOT_DIR to write snapshots")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        directory = PlaygroundFixtures.tempDirectory("snapshot")
        suiteName = "playground-snapshot-\(UUID().uuidString)"
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(nativeSpeed: Bool, voices: [[String: Any]]) async throws -> PlaygroundModel {
        let model = PlaygroundModel(
            client: DaemonClient(baseURL: baseURL, session: MockURLProtocol.session()),
            render: RenderClient(baseURL: baseURL, session: MockURLProtocol.session()),
            store: PlaygroundTakeStore(directory: directory),
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            preferredVoice: { nil }
        )
        let engines = PlaygroundFixtures.json([
            "active": "kokoro",
            "engines": [PlaygroundFixtures.engineJSON(id: "kokoro", name: "Kokoro", nativeSpeed: nativeSpeed)],
        ])
        let voiceData = PlaygroundFixtures.json(["voices": voices])
        let formats = PlaygroundFixtures.json(["formats": [
            ["id": "wav", "label": "WAV", "available": true, "ext": "wav", "mime": "audio/wav"],
            ["id": "m4a", "label": "M4A (AAC)", "available": true, "ext": "m4a", "mime": "audio/mp4"],
            ["id": "mp3", "label": "MP3", "available": false, "ext": "mp3", "mime": "audio/mpeg", "reason": "needs ffmpeg or lame"],
        ]])
        MockURLProtocol.enqueue { PlaygroundFixtures.respond($0, body: engines) }
        MockURLProtocol.enqueue { PlaygroundFixtures.respond($0, body: voiceData) }
        MockURLProtocol.enqueue { PlaygroundFixtures.respond($0, body: formats) }
        await model.refresh()
        return model
    }

    private static let voices: [[String: Any]] = [
        ["id": "af_heart", "label": "Heart (female)", "lang": "en-us", "default": true],
        ["id": "af_bella", "label": "Bella (female)", "lang": "en-us", "default": false],
        ["id": "am_michael", "label": "Michael (male)", "lang": "en-us", "default": false],
        ["id": "am_adam", "label": "Adam (male)", "lang": "en-us", "default": false],
    ]

    private func speech(seconds: Double) -> Data {
        // A tone with a swell, so the waveform has a shape.
        let rate = 8_000
        let count = Int(seconds * Double(rate))
        let samples = (0..<count).map { index -> Int16 in
            let t = Double(index) / Double(rate)
            let envelope = 0.25 + 0.75 * abs(sin(t * 2.3)) * abs(sin(t * 0.7 + 1))
            return Int16(20_000 * envelope * sin(t * 2 * .pi * 180))
        }
        return PlaygroundFixtures.wav16(samples, sampleRate: rate)
    }

    func testFullPlaygroundAtMinimumAndDefaultWidth() async throws {
        let model = try await makeModel(nativeSpeed: true, voices: Self.voices)
        let text = PlaygroundText.samples[1].text
        let group = "g_snapshot"
        for (index, voice) in Self.voices.enumerated() {
            let id = voice["id"] as? String ?? ""
            var draft = PlaygroundFixtures.draft(text: text, voice: id, groupId: group, audio: speech(seconds: 3 + Double(index)))
            draft.voiceLabel = voice["label"] as? String ?? id
            try await model.store.add(draft)
        }
        var single = PlaygroundFixtures.draft(text: PlaygroundText.samples[0].text, audio: speech(seconds: 9))
        single.voiceLabel = "Heart (female)"
        single.speed = 1.25
        let take = try await model.store.add(single)
        model.select(take)
        model.draft.text = text
        model.toggleCompareVoice("af_heart")
        model.toggleCompareVoice("am_adam")
        model.notice = PlaygroundNotice(
            .error,
            RenderAPIError.engineDown.errorDescription.map { $0 + " Open Engine and press Restart, then try again." } ?? "",
            action: .openEngine)

        try snapshot(model, width: minimumWidth, name: "playground-minimum")
        try snapshot(model, width: defaultWidth, name: "playground-default")
    }

    func testEmptyOverLimitOneVoiceEngine() async throws {
        let model = try await makeModel(
            nativeSpeed: false,
            voices: [["id": "chatterbox", "label": "Built-in voice", "lang": "en", "default": true]])
        model.draft.text = String(repeating: "A sentence that goes on. ", count: 1_700)
        try snapshot(model, width: minimumWidth, name: "playground-overlimit-onevoice")
    }

    private func snapshot(_ model: PlaygroundModel, width: CGFloat, name: String) throws {
        let root = PaneScaffold(
            title: DashboardPane.playground.title,
            subtitle: DashboardPane.playground.subtitle,
            scrolls: false
        ) {
            PlaygroundEngineBadge(model: model) {}
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                if let notice = model.notice {
                    PlaygroundNoticeBanner(notice: notice, onAction: { _ in }, onDismiss: {})
                }
                PlaygroundEditorCard(model: model, draft: model.draft, onSendToStudio: {})
                PlaygroundControlsCard(model: model, draft: model.draft)
                PlaygroundTakesSection(model: model, store: model.store, player: model.player)
            }
        }
        .frame(width: width)
        .preferredColorScheme(.dark)

        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1_600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1_600)
        host.layoutSubtreeIfNeeded()
        let height = min(3_000, max(400, host.fittingSize.height))
        window.setContentSize(NSSize(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5, "\(name): nothing is wider than the pane")

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let file = output.appendingPathComponent("\(name).png")
        try png.write(to: file)
        print("snapshot: \(file.path) \(Int(width))×\(Int(height))")
        window.close()
    }
}
