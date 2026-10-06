// TranscriptStoreTests.swift — the transcript follows the read queue, and a
// jump to audio the player doesn't hold restarts the read in place.
//
// A fake performer stands in for AppDispatcher (as in ReadQueueTests) and
// the player is a real AudioPlayer that is never given audio, so nothing
// here plays sound. The seek path, which needs audio, is in
// AudioPlayerTranscriptSeekTests.
import XCTest

@testable import Myna

@MainActor
private final class RecordingPerformer: ReadPerformer {
    private(set) var performed: [(read: QueuedRead, token: Int)] = []
    weak var queue: ReadQueue?
    var isReading: Bool { true }

    func perform(_ read: QueuedRead, token: Int) { performed.append((read, token)) }
    func halt() {}

    /// End the current read the way a normal one ends.
    func finishCurrent() {
        guard let token = performed.last?.token else { return }
        queue?.synthesisDidEnd(token: token, failure: nil, playerIdle: false)
        queue?.playbackDidDrain()
    }
}

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private var performers: [RecordingPerformer] = []
    /// The store holds its player weakly (AppDelegate owns it in the app).
    private var players: [AudioPlayer] = []
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites.removeAll()
        performers.removeAll()
        players.removeAll()
    }

    private struct Fixture {
        let store: TranscriptStore
        let queue: ReadQueue
        let performer: RecordingPerformer
    }

    private func makeStore(
        visibility: TranscriptVisibility = .onRequest, autoWords: Int = 200
    ) -> Fixture {
        let suite = "transcript-store-\(UUID().uuidString)"
        suites.append(suite)
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(visibility.rawValue, forKey: TranscriptVisibility.defaultsKey)
        defaults.set(autoWords, forKey: TranscriptAutoOpen.defaultsKey)
        let performer = RecordingPerformer()
        performers.append(performer)
        let queue = ReadQueue(performer: performer)
        performer.queue = queue
        let store = TranscriptStore(queue: queue, defaults: defaults)
        let player = AudioPlayer()
        players.append(player)
        store.attach(player: player)
        return Fixture(store: store, queue: queue, performer: performer)
    }

    private func read(_ text: String, source: ReadSource = .selection) -> QueuedRead {
        QueuedRead(text: text, source: source, appBundleId: "com.apple.Safari", appName: "Safari")
    }

    private func chunk(_ text: String, _ duration: TimeInterval = 2) -> TranscriptChunk {
        TranscriptChunk(text: text, duration: duration)
    }

    // MARK: - following the queue

    func test_a_read_that_starts_gets_a_fresh_transcript() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        XCTAssertNil(store.transcript)
        let first = read("First read. It has two sentences.")
        queue.enqueue(first)

        XCTAssertEqual(store.transcript?.readID, first.id)
        XCTAssertEqual(store.transcript?.title, "First read. It has two sentences.")
        XCTAssertEqual(store.transcript?.appName, "Safari")
        XCTAssertEqual(store.transcript?.sentences, [], "nothing until audio reaches the player")

        store.didEnqueue(readID: first.id, chunks: [chunk("First read."), chunk("It has two sentences.")])
        XCTAssertEqual(store.transcript?.sentences.map(\.text), ["First read.", "It has two sentences."])
        XCTAssertFalse(store.transcript?.synthesisDone ?? true)
        store.synthesisDidEnd(readID: first.id)
        XCTAssertTrue(store.transcript?.synthesisDone ?? false)
    }

    func test_the_transcript_switches_when_the_queue_moves_on() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        let performer = fixture.performer
        let first = read("First.")
        let second = read("Second.")
        queue.enqueue(first)
        store.didEnqueue(readID: first.id, chunks: [chunk("First.")])
        XCTAssertEqual(queue.enqueue(second), .queued(position: 1))
        XCTAssertEqual(store.transcript?.readID, first.id, "a waiting read doesn't take over")
        XCTAssertEqual(store.queuedLabel, "+1 queued")

        performer.finishCurrent()
        XCTAssertEqual(store.transcript?.readID, second.id)
        XCTAssertEqual(store.transcript?.sentences, [])
        XCTAssertNil(store.transcript?.ending)
        XCTAssertNil(store.queuedLabel)
    }

    func test_chunks_for_another_read_are_ignored() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        let first = read("First.")
        let second = read("Second.")
        queue.enqueue(first)
        queue.submit(second, placement: .playNow)
        // A late chunk from the read that was replaced.
        store.didEnqueue(readID: first.id, chunks: [chunk("First.")])
        XCTAssertEqual(store.transcript?.readID, second.id)
        XCTAssertEqual(store.transcript?.sentences, [])
    }

    func test_when_the_queue_goes_idle_the_last_text_stays() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        let performer = fixture.performer
        let only = read("Only one. Then another.")
        queue.enqueue(only)
        store.didEnqueue(readID: only.id, chunks: [chunk("Only one. Then another.")])
        performer.finishCurrent()

        XCTAssertNil(queue.current)
        XCTAssertEqual(store.transcript?.readID, only.id)
        XCTAssertEqual(store.transcript?.sentences.count, 2)
        // This player never had audio, so the read didn't reach its end.
        XCTAssertEqual(store.transcript?.ending, .stopped)
        XCTAssertTrue(store.transcript?.synthesisDone ?? false)
        XCTAssertNil(store.currentIndex)

        // No more chunks once it's over.
        store.didEnqueue(readID: only.id, chunks: [chunk("Late.")])
        XCTAssertEqual(store.transcript?.sentences.count, 2)
    }

    // MARK: - restart in place

    func test_jumping_into_a_finished_read_restarts_it_from_that_sentence() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        let performer = fixture.performer
        let original = read("One. Two. Three. Four.", source: .claudeCode)
        queue.enqueue(original)
        store.didEnqueue(readID: original.id, chunks: [chunk("One. Two."), chunk("Three. Four.")])
        performer.finishCurrent()

        store.jump(to: 2)

        let restarted = performer.performed.last?.read
        XCTAssertEqual(performer.performed.count, 2)
        XCTAssertEqual(restarted?.text, "Three. Four.")
        XCTAssertEqual(restarted?.source, .claudeCode, "same source")
        XCTAssertEqual(restarted?.appBundleId, "com.apple.Safari", "same app, so the same voice")
        XCTAssertEqual(restarted?.mode, .full)
        XCTAssertEqual(queue.current?.id, restarted?.id)

        // The transcript carries on in place: same title, the first two
        // sentences kept (without audio), the rest arriving again.
        XCTAssertEqual(store.transcript?.readID, restarted?.id)
        XCTAssertEqual(store.transcript?.title, "One. Two. Three. Four.")
        XCTAssertEqual(store.transcript?.sentences.map(\.text), ["One.", "Two."])
        XCTAssertNil(store.transcript?.ending)
        store.didEnqueue(readID: restarted?.id ?? UUID(), chunks: [chunk("Three. Four.")])
        XCTAssertEqual(store.transcript?.sentences.map(\.text), ["One.", "Two.", "Three.", "Four."])
        XCTAssertEqual(store.transcript?.sentences[2].anchor?.chunk, 0)
    }

    func test_a_restart_replaces_the_current_read_and_keeps_the_queue() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        let performer = fixture.performer
        let playing = read("A one. A two.")
        let waiting = read("B.")
        queue.enqueue(playing)
        queue.enqueue(waiting)
        store.didEnqueue(readID: playing.id, chunks: [chunk("A one. A two.")])

        // The player holds nothing (a fake performer), so even the current
        // read restarts rather than seeks.
        store.jump(to: 1)
        XCTAssertEqual(performer.performed.last?.read.text, "A two.")
        XCTAssertEqual(queue.items.map(\.id), [waiting.id], "the waiting read keeps its place")
    }

    func test_back_and_play_after_the_end_replay() {
        let fixture = makeStore()
        let store = fixture.store
        let queue = fixture.queue
        let performer = fixture.performer
        let original = read("One. Two. Three.")
        queue.enqueue(original)
        store.didEnqueue(readID: original.id, chunks: [chunk("One. Two. Three.")])
        performer.finishCurrent()

        store.nextSentence()
        XCTAssertEqual(performer.performed.count, 1, "nothing after the end to skip to")

        store.previousSentence()
        let replay = performer.performed.last?.read
        XCTAssertEqual(replay?.text, "Three.", "Back after the end replays the last sentence")
        store.didEnqueue(readID: replay?.id ?? UUID(), chunks: [chunk("Three.")])

        performer.finishCurrent()
        store.togglePlayPause()
        XCTAssertEqual(performer.performed.last?.read.text, "One. Two. Three.", "Play after the end starts over")
    }

    func test_skip_commands_do_nothing_without_a_transcript() {
        let fixture = makeStore()
        let store = fixture.store
        let performer = fixture.performer
        store.previousSentence()
        store.nextSentence()
        store.jump(to: 0)
        store.togglePlayPause()
        XCTAssertTrue(performer.performed.isEmpty)
    }

    // MARK: - opening by itself

    func test_a_long_read_opens_the_panel_once_when_set_to_automatic() {
        let fixture = makeStore(visibility: .automatic, autoWords: 5)
        let store = fixture.store
        let queue = fixture.queue
        var opened = 0
        store.onAutoOpen = { opened += 1 }
        let long = read("irrelevant")
        queue.enqueue(long)
        store.didEnqueue(readID: long.id, chunks: [chunk("Three words here.")])
        XCTAssertEqual(opened, 0, "3 words is not longer than 5")
        store.didEnqueue(readID: long.id, chunks: [chunk("And three more.")])
        XCTAssertEqual(opened, 1)
        store.didEnqueue(readID: long.id, chunks: [chunk("Still more words arrive.")])
        XCTAssertEqual(opened, 1, "once per read")
    }

    func test_the_panel_never_opens_by_itself_otherwise() {
        for visibility in [TranscriptVisibility.onRequest, .off] {
            let fixture = makeStore(visibility: visibility, autoWords: 5)
            let store = fixture.store
            let queue = fixture.queue
            var opened = 0
            store.onAutoOpen = { opened += 1 }
            let long = read("irrelevant")
            queue.enqueue(long)
            store.didEnqueue(readID: long.id, chunks: [chunk(String(repeating: "word ", count: 50))])
            XCTAssertEqual(opened, 0, visibility.rawValue)
        }
    }
}
