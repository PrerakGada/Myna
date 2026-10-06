// TranscriptSnapshotTests.swift — draws the transcript panel (and the pill
// with its new transcript button) offscreen to PNGs, for a person to look at.
//
// Skipped unless a folder is given:
//
//   TEST_RUNNER_MYNA_TRANSCRIPT_SNAPSHOT_DIR=/tmp/shots xcodebuild test … \
//     -only-testing:MynaTests/TranscriptSnapshotTests
//
// The views are the real ones in a window that is never shown, fed a store
// set to a fixed state. Asserts only that the content fits the panel width.
import AppKit
import SwiftUI
import XCTest

@testable import Myna

@MainActor
final class TranscriptSnapshotTests: XCTestCase {
    private var output: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["MYNA_TRANSCRIPT_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_MYNA_TRANSCRIPT_SNAPSHOT_DIR to write snapshots")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private static let article = """
        The first thing to know about Kokoro is that it is small. Dr. Hexgrad trained it on a few hundred \
        hours of speech, e.g. audiobooks and podcasts, and it still sounds natural. It runs at 3.5 times \
        real time on a laptop.
        Why does that matter? Because a voice you wait for is a voice you stop using. \
        "Fast enough" turns out to mean under half a second to the first word. Myna aims for that \
        with a short first chunk, then larger ones behind it.
        Most readers never notice the seams. The ones who do usually notice the pause after a heading \
        rather than anything inside a paragraph. That is the part still being tuned.
        """

    private func sampleTranscript() -> Transcript {
        var transcript = Transcript(
            readID: UUID(), title: "The first thing to know about Kokoro is that it is small.",
            source: .article, appName: "Google Chrome")
        let parts = Self.article.components(separatedBy: "\n")
        for (index, part) in parts.enumerated() {
            transcript.appendChunk(text: part, duration: 9 + Double(index))
        }
        return transcript
    }

    func testPanelStates() throws {
        let store = TranscriptStore(queue: ReadQueue(), defaults: .standard)
        var reading = sampleTranscript()
        store.setForTesting(reading, currentIndex: 5, playback: .playing)
        try snapshot(store, name: "transcript-reading")

        reading.synthesisDone = true
        store.setForTesting(reading, currentIndex: 5, playback: .paused)
        try snapshot(store, name: "transcript-paused")

        var finished = reading
        finished.ending = .finished
        store.setForTesting(finished, currentIndex: nil, playback: .idle)
        try snapshot(store, name: "transcript-finished")

        var restarted = reading.continuation(readID: UUID(), from: 4)
        restarted.appendChunk(text: "Because a voice you wait for is a voice you stop using.", duration: 3, isPreviewOnly: true)
        store.setForTesting(restarted, currentIndex: 4, playback: .playing)
        try snapshot(store, name: "transcript-restarted-partial")

        let preparing = Transcript(readID: UUID(), title: "news.ycombinator.com", source: .article)
        store.setForTesting(preparing, currentIndex: nil, playback: .preparing)
        try snapshot(store, name: "transcript-preparing")

        store.setForTesting(nil, currentIndex: nil, playback: .idle)
        try snapshot(store, name: "transcript-empty")
    }

    func testPillWithTranscriptButton() throws {
        let model = PillView_PreviewModel.make(isSpeaking: true, isExpanded: true, withText: true)
        // The model's live player subscription delivers "idle" on the next
        // run-loop turn and would collapse the pill; let it land, then force.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        model._previewForceState(isSpeaking: true, isExpanded: true, paused: false)
        try render(PillView(viewModel: model).padding(20).background(Color(white: 0.35)),
                   size: NSSize(width: 380, height: 200), name: "pill-expanded-with-transcript-button")
    }

    private func snapshot(_ store: TranscriptStore, name: String) throws {
        let view = TranscriptPanelView(store: store, scroll: TranscriptScrollState())
        try render(view, size: TranscriptPanelController.defaultSize, name: name)
    }

    private func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 0.5, "\(name) fits")

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let file = output.appendingPathComponent("\(name).png")
        try png.write(to: file)
        print("snapshot: \(file.path)")
        window.close()
    }
}
