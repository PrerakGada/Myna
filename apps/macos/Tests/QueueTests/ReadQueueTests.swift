// ReadQueueTests.swift — pins the read queue's sequencing and the
// dispatcher's queue-or-interrupt table, against a fake performer.
//
// The fake stands in for AppDispatcher: it records what the queue asked it
// to play and lets each test drive the two halves of "a read finished"
// (synthesis ended, player drained) in whatever order the case needs.
import Combine
import XCTest

@testable import Myna

@MainActor
private final class FakePerformer: ReadPerformer {
    private(set) var performed: [(read: QueuedRead, token: Int)] = []
    private(set) var haltCount = 0
    /// What `isReading` reports. The queue only consults it to notice a lost
    /// end-of-read signal, so most tests leave it true.
    var reading = true
    /// When set, `perform` immediately reports the read as failed — models a
    /// daemon that errors before producing any audio.
    var failImmediately: String?
    weak var queue: ReadQueue?

    var isReading: Bool { reading }
    var lastToken: Int? { performed.last?.token }
    var performedTexts: [String?] { performed.map(\.read.text) }

    func perform(_ read: QueuedRead, token: Int) {
        performed.append((read, token))
        if let failImmediately {
            queue?.synthesisDidEnd(token: token, failure: failImmediately, playerIdle: true)
        }
    }

    func halt() { haltCount += 1 }
}

@MainActor
final class ReadQueueTests: XCTestCase {
    private func read(_ text: String, mode: SynthesizeMode = .full, source: ReadSource = .selection) -> QueuedRead {
        QueuedRead(text: text, mode: mode, source: source, appBundleId: "com.apple.Safari", appName: "Safari")
    }

    /// The queue holds its performer weakly (the dispatcher owns that
    /// relationship in the app), so the test case keeps each fake alive.
    private var performers: [FakePerformer] = []

    private func makeQueue(capacity: Int = ReadQueue.defaultCapacity) -> (ReadQueue, FakePerformer) {
        let performer = FakePerformer()
        performers.append(performer)
        let queue = ReadQueue(capacity: capacity, performer: performer)
        performer.queue = queue
        return (queue, performer)
    }

    /// Finish the current read the way a normal one ends: synthesis first
    /// (audio still playing), then the player drains.
    private func finishNaturally(_ queue: ReadQueue, _ performer: FakePerformer) {
        guard let token = performer.lastToken else { return XCTFail("nothing performed") }
        queue.synthesisDidEnd(token: token, failure: nil, playerIdle: false)
        queue.playbackDidDrain()
    }

    // MARK: - policy: queue or interrupt, per entry point and setting

    func test_play_clicks_always_interrupt() {
        for preference in ReadKeyWhileReading.allCases {
            XCTAssertEqual(ReadQueuePolicy.placement(for: .playClick, preference: preference), .playNow)
        }
    }

    func test_keys_and_popover_reads_follow_the_preference() {
        for entry in [ReadEntryPoint.selectionKey, .articleKey, .clipboard] {
            XCTAssertEqual(ReadQueuePolicy.placement(for: entry, preference: .queue), .queueIfBusy, "\(entry)")
            XCTAssertEqual(ReadQueuePolicy.placement(for: entry, preference: .interrupt), .playNow, "\(entry)")
        }
    }

    func test_every_entry_point_has_a_decided_placement() {
        // A new entry point must be added to the policy table deliberately.
        XCTAssertEqual(ReadEntryPoint.allCases.count, 4)
    }

    func test_preference_defaults_to_queue_and_reads_saved_value() throws {
        let suite = "ReadQueueTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ReadKeyWhileReading.current(defaults), .queue)
        defaults.set("interrupt", forKey: ReadKeyWhileReading.defaultsKey)
        XCTAssertEqual(ReadKeyWhileReading.current(defaults), .interrupt)
        defaults.set("something-newer", forKey: ReadKeyWhileReading.defaultsKey)
        XCTAssertEqual(ReadKeyWhileReading.current(defaults), .queue)
    }

    // MARK: - submit

    func test_submit_when_idle_plays_at_once() {
        let (queue, performer) = makeQueue()
        XCTAssertEqual(queue.submit(read("one"), placement: .queueIfBusy), .playing)
        XCTAssertEqual(performer.performedTexts, ["one"])
        XCTAssertEqual(queue.current?.text, "one")
        XCTAssertTrue(queue.items.isEmpty)
    }

    func test_submit_while_busy_queues_behind_the_current_read() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        XCTAssertEqual(queue.enqueue(read("two")), .queued(position: 1))
        XCTAssertEqual(queue.enqueue(read("three")), .queued(position: 2))
        XCTAssertEqual(performer.performedTexts, ["one"])
        XCTAssertEqual(queue.items.map(\.text), ["two", "three"])
        XCTAssertEqual(queue.countLabel, "+2 queued")
    }

    func test_play_now_replaces_the_current_read_and_keeps_the_waiting_ones() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        XCTAssertEqual(queue.submit(read("clicked"), placement: .playNow), .playing)
        XCTAssertEqual(performer.performedTexts, ["one", "clicked"])
        XCTAssertEqual(queue.current?.text, "clicked")
        XCTAssertEqual(queue.items.map(\.text), ["two"])
        // The replaced read's late callbacks are stale.
        let first = performer.performed[0].token
        queue.synthesisDidEnd(token: first, failure: nil, playerIdle: true)
        XCTAssertEqual(queue.current?.text, "clicked")
    }

    // MARK: - natural completion

    func test_read_ends_only_after_synthesis_ends_and_player_drains() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        let token = performer.lastToken ?? -1
        queue.synthesisDidEnd(token: token, failure: nil, playerIdle: false)
        XCTAssertEqual(queue.current?.text, "one", "audio is still playing")
        queue.playbackDidDrain()
        XCTAssertEqual(performer.performedTexts, ["one", "two"])
        XCTAssertEqual(queue.current?.text, "two")
        XCTAssertTrue(queue.items.isEmpty)
    }

    func test_player_already_idle_when_synthesis_ends_advances_at_once() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.synthesisDidEnd(token: performer.lastToken ?? -1, failure: nil, playerIdle: true)
        XCTAssertEqual(queue.current?.text, "two")
    }

    func test_drain_before_synthesis_ends_is_a_mid_read_underrun() {
        // Streaming mode: chunk 0 can finish before chunk 1 arrives.
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.playbackDidDrain()
        XCTAssertEqual(queue.current?.text, "one")
        XCTAssertEqual(performer.performed.count, 1)
    }

    func test_last_read_finishing_leaves_the_queue_idle_without_halting() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        finishNaturally(queue, performer)
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.isBusy)
        XCTAssertEqual(performer.haltCount, 0, "the player is already idle; nothing to stop")
    }

    func test_whole_queue_plays_in_order() {
        let (queue, performer) = makeQueue()
        for text in ["a", "b", "c", "d"] { queue.enqueue(read(text)) }
        for _ in 0..<4 { finishNaturally(queue, performer) }
        XCTAssertEqual(performer.performedTexts, ["a", "b", "c", "d"])
        XCTAssertNil(queue.current)
    }

    // MARK: - stop

    func test_stop_clears_everything_and_halts() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.enqueue(read("three"))
        queue.stop()
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(performer.haltCount, 1)
        // Late signals from the stopped read change nothing.
        queue.synthesisDidEnd(token: performer.lastToken ?? -1, failure: nil, playerIdle: false)
        queue.playbackDidDrain()
        XCTAssertNil(queue.current)
        XCTAssertEqual(performer.performed.count, 1)
    }

    func test_player_stopped_elsewhere_clears_the_queue() {
        // The pill's Stop button calls player.stop() directly.
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.playbackWasStopped()
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(performer.haltCount, 1, "halt cancels any synthesis still in flight")
    }

    func test_player_stopped_while_queue_idle_is_ignored() {
        let (queue, performer) = makeQueue()
        queue.playbackWasStopped()
        XCTAssertEqual(performer.haltCount, 0)
    }

    func test_stop_in_the_gap_between_reads() {
        // A finishes, B is handed to the performer, and Stop lands before B
        // has produced anything. B's late callbacks must not revive it.
        let (queue, performer) = makeQueue()
        queue.enqueue(read("A"))
        queue.enqueue(read("B"))
        finishNaturally(queue, performer)
        let tokenB = performer.lastToken ?? -1
        XCTAssertEqual(queue.current?.text, "B")
        queue.stop()
        queue.synthesisDidEnd(token: tokenB, failure: nil, playerIdle: true)
        queue.playbackDidDrain()
        XCTAssertNil(queue.current)
        XCTAssertEqual(performer.performedTexts, ["A", "B"])
    }

    // MARK: - skip

    func test_skip_starts_the_next_read() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        let oldToken = performer.lastToken ?? -1
        queue.skip()
        XCTAssertEqual(queue.current?.text, "two")
        XCTAssertEqual(performer.performedTexts, ["one", "two"])
        // The skipped read's callbacks are stale and can't skip "two" too.
        queue.synthesisDidEnd(token: oldToken, failure: nil, playerIdle: true)
        queue.playbackDidDrain()
        XCTAssertEqual(queue.current?.text, "two")
    }

    func test_skip_with_nothing_waiting_ends_the_current_read() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.skip()
        XCTAssertNil(queue.current)
        XCTAssertEqual(performer.haltCount, 1)
    }

    func test_skip_while_idle_does_nothing() {
        let (queue, performer) = makeQueue()
        queue.skip()
        XCTAssertEqual(performer.haltCount, 0)
        XCTAssertTrue(performer.performed.isEmpty)
    }

    // MARK: - dedupe

    func test_same_text_as_the_current_read_is_a_duplicate() {
        let (queue, _) = makeQueue()
        queue.enqueue(read("The same paragraph."))
        XCTAssertEqual(queue.enqueue(read("The same paragraph.")), .duplicate)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func test_same_text_already_waiting_is_a_duplicate_even_with_other_whitespace() {
        let (queue, _) = makeQueue()
        queue.enqueue(read("playing"))
        queue.enqueue(read("Second paragraph\nof text."))
        queue.enqueue(read("third"))
        XCTAssertEqual(queue.enqueue(read("  Second paragraph of text.\n")), .duplicate)
        XCTAssertEqual(queue.items.map(\.text), ["Second paragraph\nof text.", "third"])
    }

    func test_summary_of_the_same_text_is_not_a_duplicate() {
        let (queue, _) = makeQueue()
        queue.enqueue(read("paragraph"))
        XCTAssertEqual(queue.enqueue(read("paragraph", mode: .summary)), .queued(position: 1))
    }

    func test_same_article_url_is_a_duplicate() {
        let (queue, _) = makeQueue()
        queue.enqueue(QueuedRead(url: "https://example.com/a", source: .article))
        XCTAssertEqual(queue.enqueue(QueuedRead(url: "https://example.com/a", source: .article)), .duplicate)
        XCTAssertEqual(
            queue.enqueue(QueuedRead(url: "https://example.com/b", source: .article)), .queued(position: 1))
    }

    func test_text_that_already_played_can_be_queued_again() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("once"))
        queue.enqueue(read("other"))
        finishNaturally(queue, performer)
        XCTAssertEqual(queue.enqueue(read("once")), .queued(position: 1))
    }

    // MARK: - capacity

    func test_full_queue_refuses_and_changes_nothing() {
        let (queue, _) = makeQueue(capacity: 3)
        queue.enqueue(read("playing"))
        for index in 1...3 { XCTAssertEqual(queue.enqueue(read("r\(index)")), .queued(position: index)) }
        XCTAssertEqual(queue.enqueue(read("r4")), .full)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.current?.text, "playing")
    }

    func test_play_now_is_not_blocked_by_a_full_queue() {
        let (queue, _) = makeQueue(capacity: 1)
        queue.enqueue(read("playing"))
        queue.enqueue(read("waiting"))
        XCTAssertEqual(queue.submit(read("clicked"), placement: .playNow), .playing)
        XCTAssertEqual(queue.current?.text, "clicked")
    }

    func test_default_capacity_is_twenty() {
        XCTAssertEqual(ReadQueue.defaultCapacity, 20)
    }

    // MARK: - errors skip and go on

    func test_failed_read_skips_to_the_next() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.synthesisDidEnd(token: performer.lastToken ?? -1, failure: "daemon 502", playerIdle: true)
        XCTAssertEqual(queue.current?.text, "two")
    }

    func test_partial_failure_plays_what_arrived_before_moving_on() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.synthesisDidEnd(token: performer.lastToken ?? -1, failure: "stream cut", playerIdle: false)
        XCTAssertEqual(queue.current?.text, "one")
        queue.playbackDidDrain()
        XCTAssertEqual(queue.current?.text, "two")
    }

    func test_every_read_failing_at_once_drains_the_queue_without_looping() {
        // The performer reports failure synchronously from inside perform —
        // a dead daemon. The queue must walk through and end idle.
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.enqueue(read("three"))
        performer.failImmediately = "connection refused"
        queue.skip()
        XCTAssertEqual(performer.performedTexts, ["one", "two", "three"])
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.items.isEmpty)
    }

    // MARK: - races at the boundary

    func test_enqueue_while_the_last_read_is_draining_waits_for_it() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.synthesisDidEnd(token: performer.lastToken ?? -1, failure: nil, playerIdle: false)
        // Pressed in the last second of "one".
        XCTAssertEqual(queue.enqueue(read("two")), .queued(position: 1))
        queue.playbackDidDrain()
        XCTAssertEqual(queue.current?.text, "two")
        XCTAssertEqual(performer.performedTexts, ["one", "two"])
    }

    func test_enqueue_just_after_the_last_read_finished_plays_at_once() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        finishNaturally(queue, performer)
        XCTAssertEqual(queue.enqueue(read("two")), .playing)
        XCTAssertEqual(performer.performedTexts, ["one", "two"])
    }

    func test_lost_end_signal_does_not_strand_later_reads() {
        // The queue thinks "one" is still going, but the performer is idle
        // with nothing in flight: the next read must not wait forever.
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        performer.reading = false
        let result = queue.enqueue(read("three"))
        XCTAssertEqual(queue.current?.text, "two", "the waiting read goes first")
        XCTAssertEqual(result, .queued(position: 1))
        XCTAssertEqual(performer.performedTexts, ["one", "two"])
    }

    func test_duplicate_drain_signal_advances_only_once() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(read("two"))
        queue.enqueue(read("three"))
        queue.synthesisDidEnd(token: performer.lastToken ?? -1, failure: nil, playerIdle: false)
        queue.playbackDidDrain()
        queue.playbackDidDrain()
        XCTAssertEqual(queue.current?.text, "two")
    }

    // MARK: - remove / clear

    func test_remove_drops_one_waiting_read() {
        let (queue, _) = makeQueue()
        queue.enqueue(read("playing"))
        queue.enqueue(read("a"))
        queue.enqueue(read("b"))
        let target = queue.items[0].id
        queue.remove(id: target)
        XCTAssertEqual(queue.items.map(\.text), ["b"])
        XCTAssertEqual(queue.current?.text, "playing")
    }

    func test_clear_empties_the_queue_but_lets_the_current_read_finish() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("playing"))
        queue.enqueue(read("a"))
        queue.clear()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertEqual(queue.current?.text, "playing")
        XCTAssertEqual(performer.haltCount, 0)
        finishNaturally(queue, performer)
        XCTAssertNil(queue.current)
    }

    // MARK: - captured context

    func test_queued_read_keeps_the_app_it_came_from() {
        let (queue, performer) = makeQueue()
        queue.enqueue(read("one"))
        queue.enqueue(QueuedRead(text: "from the terminal", source: .selection,
                                 appBundleId: "com.googlecode.iterm2", appName: "iTerm2"))
        finishNaturally(queue, performer)
        XCTAssertEqual(performer.performed.last?.read.appBundleId, "com.googlecode.iterm2")
        XCTAssertEqual(performer.performed.last?.read.source, .selection)
    }

    func test_preview_is_the_first_few_words() {
        let long = QueuedRead(text: "One two three four five six seven eight nine ten", source: .selection)
        XCTAssertEqual(long.preview, "One two three four five six seven eight\u{2026}")
        let short = QueuedRead(text: "  Just\nthis  ", source: .clipboard)
        XCTAssertEqual(short.preview, "Just this")
        let article = QueuedRead(url: "https://www.example.com/post/1", source: .article)
        XCTAssertEqual(article.preview, "www.example.com")
    }

    func test_count_label() {
        XCTAssertNil(ReadQueue.countLabel(for: 0))
        XCTAssertEqual(ReadQueue.countLabel(for: 2), "+2 queued")
    }

    // MARK: - the player's end-of-session signal

    func test_player_reports_stopped_only_when_a_session_was_live() {
        let player = AudioPlayer()
        var ends: [AudioPlayer.SessionEnd] = []
        let sub = player.sessionEnds.sink { ends.append($0) }
        defer { sub.cancel() }
        player.stop()
        XCTAssertEqual(ends, [], "stopping an idle player ends nothing")
        player.isLoading = true
        player.stop()
        XCTAssertEqual(ends, [.stopped], "stopping during synthesis ends that read")
        XCTAssertEqual(player.state, .idle)
    }
}
