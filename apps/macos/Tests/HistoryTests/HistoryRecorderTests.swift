// HistoryRecorderTests.swift — the glue between playback and history.
//
// The recorder is the piece most likely to be wrong in a way nobody
// notices: it produces the numbers, so a bug here shows up as plausible
// but false analytics rather than as a crash. The cases that matter:
//
//   • a superseding read must close the previous record, not the new one
//     (AppDispatcher stops the player BEFORE starting the next read, so
//     the idle transition arrives while the new record is already open)
//   • "completed" has to mean heard-to-the-end, within tolerance
//   • a failure must be recorded as failed, with its message
import AVFoundation
import XCTest

@testable import Myna

@MainActor
final class HistoryRecorderTests: XCTestCase {

    private var directory: URL!
    private var store: HistoryStore!
    private var player: AudioPlayer!
    private var recorder: HistoryRecorder!

    override func setUp() async throws {
        // No super.setUp(): sending the XCTestCase across actors fails CI's Swift 6 (see PillSettingsTests).
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-recorder-tests-\(UUID().uuidString)")
        store = HistoryStore(directory: directory, fileName: "history.json")
        player = AudioPlayer()
        recorder = HistoryRecorder(store: store, player: player)
    }

    override func tearDown() async throws {
        player?.stop()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @discardableResult
    private func begin(_ title: String = "A read", text: String? = "one two three") -> String {
        recorder.begin(
            HistoryRecorder.Start(
                title: title,
                text: text,
                source: .selection,
                voice: "af_heart",
                appBundleId: "com.apple.Safari",
                appName: "Safari"
            )
        )
    }

    // MARK: - opening a record

    func testBeginOpensALiveRecordWithMeasuredText() throws {
        begin("Hello", text: "one two three four")
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.title, "Hello")
        XCTAssertEqual(event.outcome, .reading)
        XCTAssertEqual(event.words, 4)
        XCTAssertEqual(event.characters, 18)
        XCTAssertEqual(event.appName, "Safari")
        XCTAssertNotNil(store.liveEvent)
    }

    func testBeginClosesAnyPreviousRecord() {
        begin("First")
        begin("Second")
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.filter { $0.outcome == .reading }.count, 1)
        XCTAssertEqual(store.liveEvent?.title, "Second")
        XCTAssertEqual(store.events.last?.outcome, .stopped)
    }

    // MARK: - latency

    func testNoteFirstAudioIsRecordedOnceAndOnlyOnce() throws {
        begin()
        recorder.noteFirstAudio()
        let first = try XCTUnwrap(store.events.first?.firstAudioMs)
        recorder.noteFirstAudio()
        XCTAssertEqual(store.events.first?.firstAudioMs, first)
    }

    func testNoteFirstAudioWithNoOpenRecordIsSafe() {
        recorder.noteFirstAudio()
        XCTAssertTrue(store.events.isEmpty)
    }

    // MARK: - refining

    func testRefineUpdatesTitleAndLanguage() throws {
        begin("example.com")
        recorder.refine(title: "The real article title", detectedLang: "fr")
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.title, "The real article title")
        XCTAssertEqual(event.detectedLang, "fr")
    }

    func testRefineIgnoresAnEmptyTitle() throws {
        begin("keep me")
        recorder.refine(title: "")
        XCTAssertEqual(store.events.first?.title, "keep me")
    }

    // MARK: - closing

    func testFinalizeWithNoAudioIsStopped() throws {
        begin()
        recorder.finalizeActive()
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.outcome, .stopped)
        XCTAssertNotNil(event.endedAtMs)
        XCTAssertNil(store.liveEvent)
    }

    func testFailureIsRecordedWithItsMessage() throws {
        begin()
        recorder.noteFailure("engine returned 502")
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.outcome, .failed)
        XCTAssertEqual(event.errorMessage, "engine returned 502")
    }

    func testFinalizeIsIdempotent() {
        begin()
        recorder.finalizeActive()
        let snapshot = store.events
        recorder.finalizeActive()
        XCTAssertEqual(store.events, snapshot)
    }

    /// Heard to within the tolerance = completed; short of it = stopped.
    /// This is the rule behind the Overview's "Finished" percentage.
    func testCompletionIsDecidedByHowMuchWasHeard() throws {
        // Drive the player with real buffers so position/duration publish
        // exactly as they do in the app.
        begin("Complete")
        player.enqueueAll([Self.silence(seconds: 0.4), Self.silence(seconds: 0.4)])
        try spin(seconds: 1.4)
        // The clip drained on its own, so the player returned to idle and
        // the recorder closed the record.
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.outcome, .completed)
        XCTAssertGreaterThan(event.audioSeconds, 0.5)
        XCTAssertEqual(event.listenedSeconds, event.audioSeconds, accuracy: 0.35)
    }

    func testStoppingPartWayThroughRecordsWhatWasHeard() throws {
        begin("Interrupted")
        player.enqueueAll([Self.silence(seconds: 3.0)])
        try spin(seconds: 0.6)
        player.stop()
        try spin(seconds: 0.3)
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.outcome, .stopped)
        XCTAssertGreaterThan(event.listenedSeconds, 0.1)
        XCTAssertLessThan(event.listenedSeconds, 2.5)
    }

    /// The ordering trap: player.stop() then begin() — the idle transition
    /// lands after the NEXT record is already open. It must not close it.
    func testStopThenBeginDoesNotImmediatelyCloseTheNewRecord() throws {
        begin("First")
        player.enqueueAll([Self.silence(seconds: 2.0)])
        try spin(seconds: 0.3)

        player.stop()          // AppDispatcher does this first…
        begin("Second")        // …and opens the next record immediately after.
        try spin(seconds: 0.4)

        XCTAssertEqual(
            store.liveEvent?.title, "Second",
            "the incoming read must still be open after the outgoing read's idle hop")
    }

    // MARK: - helpers

    /// Spin the main runloop so Combine sinks and MainActor hops run.
    private func spin(seconds: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// A buffer of silence — enough for the player to schedule, report a
    /// duration for, and drain, with no audible output in CI.
    static func silence(seconds: Double, sampleRate: Double = 24_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) { channel[index] = 0 }
        }
        return buffer
    }
}
