// AutoReadEngineTests.swift — the auto-read queue's rules, driven event by
// event with a fake clock: ordering and serialisation, never talking over
// the user's own read, the microphone hold, coming back mid-read, and the
// idle-alert quiet period.
import XCTest

@testable import Myna

final class AutoReadEngineTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var engine = AutoReadEngine()
    private var away = true

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSince1970: 1_000_000)
        engine = AutoReadEngine()
        away = true
    }

    // MARK: helpers

    private func reply(_ id: String, session: String = "s", passages: [String] = ["Only passage."]) -> AutoReadJob {
        AutoReadJob(itemId: id, kind: .reply, sessionKey: session, prefix: "From \(session).", passages: passages)
    }

    private func alert(_ id: String, session: String = "s", idle: Bool = false, requiresAway: Bool = true) -> AutoReadJob {
        AutoReadJob(itemId: id, kind: .alert(idle: idle), sessionKey: session,
                    requiresAway: requiresAway, passages: ["\(session) needs you"])
    }

    private func tick(busy: Bool = false, call: Bool = false, advance: TimeInterval = 0.5) -> [AutoReadEngine.Effect] {
        now = now.addingTimeInterval(advance)
        let conditions = AutoReadEngine.Conditions(playerBusy: busy, callActive: call, now: now)
        let isAway = away
        return engine.tick(conditions) { _ in isAway }
    }

    /// Start the queued head, let its read begin, play it to the end and settle.
    private func playActivePassageToEnd() -> [AutoReadEngine.Effect] {
        XCTAssertEqual(engine.readStarted(), [])
        engine.progress(position: 10, duration: 10)
        _ = tick(busy: true)
        _ = tick(busy: false)  // player idle: settling begins
        return tick(busy: false, advance: AutoReadEngine.settleSeconds)
    }

    private func spoken(_ effects: [AutoReadEngine.Effect]) -> [String] {
        effects.compactMap { if case .speak(let text) = $0 { return text } else { return nil } }
    }

    // MARK: serialisation and order

    func test_replies_play_one_after_another_in_arrival_order_with_project_prefix() {
        XCTAssertTrue(engine.enqueue(reply("a", session: "myna"), now: now))
        XCTAssertTrue(engine.enqueue(reply("b", session: "gala"), now: now))

        XCTAssertEqual(spoken(tick()), ["From myna. Only passage."])
        // While the first is playing, the second never starts.
        XCTAssertEqual(engine.readStarted(), [])
        XCTAssertEqual(spoken(tick(busy: true)), [])
        engine.progress(position: 10, duration: 10)
        _ = tick(busy: false)
        XCTAssertEqual(tick(busy: false, advance: AutoReadEngine.settleSeconds), [.heardInFull(itemId: "a")])

        XCTAssertEqual(spoken(tick()), ["From gala. Only passage."])
        XCTAssertEqual(playActivePassageToEnd(), [.heardInFull(itemId: "b")])
        XCTAssertFalse(engine.hasWork)
    }

    func test_multi_passage_reply_speaks_each_passage_in_turn_prefix_once() {
        engine.enqueue(reply("a", session: "myna", passages: ["One.", "Two.", "Three."]), now: now)
        XCTAssertEqual(spoken(tick()), ["From myna. One."])
        XCTAssertEqual(playActivePassageToEnd(), [])
        XCTAssertEqual(spoken(tick()), ["Two."])
        XCTAssertEqual(playActivePassageToEnd(), [])
        XCTAssertEqual(spoken(tick()), ["Three."])
        XCTAssertEqual(playActivePassageToEnd(), [.heardInFull(itemId: "a")])
    }

    func test_duplicates_and_empty_jobs_are_refused() {
        XCTAssertTrue(engine.enqueue(reply("a"), now: now))
        XCTAssertFalse(engine.enqueue(reply("a"), now: now))
        _ = tick()
        XCTAssertFalse(engine.enqueue(reply("a"), now: now), "already active")
        XCTAssertFalse(engine.enqueue(reply("z", passages: []), now: now))
    }

    func test_alert_jumps_unstarted_replies_but_not_a_started_one() {
        engine.enqueue(reply("r1", session: "one", passages: ["P1.", "P2."]), now: now)
        engine.enqueue(reply("r2", session: "two"), now: now)
        _ = tick()                       // r1 passage 1 requested
        _ = playActivePassageToEnd()     // r1 goes back to the head with next = 1
        engine.enqueue(alert("a1", session: "three"), now: now)
        XCTAssertEqual(engine.queue.map(\.itemId), ["r1", "a1", "r2"])
    }

    func test_newer_alert_replaces_queued_alert_of_same_session() {
        engine.enqueue(reply("r", session: "busy"), now: now)
        _ = tick()  // r is active, so the alerts below wait in the queue
        engine.enqueue(alert("a1", session: "x"), now: now)
        engine.enqueue(alert("a2", session: "x"), now: now)
        engine.enqueue(alert("b1", session: "y"), now: now)
        XCTAssertEqual(engine.queue.map(\.itemId), ["a2", "b1"])
    }

    // MARK: never interrupt the user's own read

    func test_waits_while_the_users_read_is_playing_or_paused_then_starts() {
        engine.enqueue(reply("a"), now: now)
        XCTAssertEqual(tick(busy: true), [])
        XCTAssertEqual(tick(busy: true, advance: 30), [])
        XCTAssertNil(engine.activeItemId)
        XCTAssertEqual(spoken(tick(busy: false)).count, 1)
    }

    func test_a_read_the_user_starts_mid_passage_preempts_and_hands_back_the_rest() {
        engine.enqueue(reply("a", passages: ["One.", "Two."]), now: now)
        _ = tick()
        _ = playActivePassageToEnd()
        _ = tick()                              // passage 2 requested
        XCTAssertEqual(engine.readStarted(), [])  // ours
        engine.progress(position: 3, duration: 20)
        // The user presses the hotkey: a second read starts over ours.
        XCTAssertEqual(engine.readStarted(), [.partlyHeard(itemId: "a", rest: "Two.")])
        XCTAssertFalse(engine.hasWork)
    }

    func test_user_read_starting_while_our_finished_passage_settles_counts_it_heard() {
        engine.enqueue(reply("a", passages: ["One.", "Two."]), now: now)
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        engine.progress(position: 10, duration: 10)
        _ = tick(busy: false)                   // idle, settling
        XCTAssertEqual(engine.readStarted(), [.partlyHeard(itemId: "a", rest: "Two.")])
    }

    func test_user_pressing_stop_hands_back_from_the_cut_passage() {
        engine.enqueue(reply("a", passages: ["One.", "Two."]), now: now)
        _ = tick()
        _ = playActivePassageToEnd()
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        engine.progress(position: 4, duration: 20)
        _ = tick(busy: false)
        XCTAssertEqual(tick(busy: false, advance: AutoReadEngine.settleSeconds),
                       [.partlyHeard(itemId: "a", rest: "Two.")])
    }

    func test_brief_idle_mid_passage_is_not_mistaken_for_the_end() {
        engine.enqueue(reply("a", passages: ["One.", "Two."]), now: now)
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        engine.progress(position: 5, duration: 5)   // drained up to a late chunk
        XCTAssertEqual(tick(busy: false, advance: 0.5), [])
        XCTAssertEqual(tick(busy: true, advance: 0.5), [])  // the late chunk arrived
        engine.progress(position: 12, duration: 12)
        XCTAssertEqual(tick(busy: false, advance: 0.5), [])
        XCTAssertEqual(tick(busy: false, advance: AutoReadEngine.settleSeconds), [])
        XCTAssertEqual(spoken(tick()), ["Two."])
    }

    func test_nothing_heard_leaves_the_card_alone() {
        engine.enqueue(reply("a"), now: now)
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        // Synthesis failed: the read ended with no audio at all.
        _ = tick(busy: false)
        XCTAssertEqual(tick(busy: false, advance: AutoReadEngine.settleSeconds), [])
        XCTAssertFalse(engine.hasWork)
    }

    func test_a_passage_whose_read_never_starts_is_abandoned() {
        engine.enqueue(reply("a"), now: now)
        _ = tick()
        XCTAssertEqual(tick(advance: AutoReadEngine.startTimeout + 1), [])
        XCTAssertFalse(engine.hasWork)
    }

    // MARK: coming back

    func test_returning_mid_passage_finishes_it_then_hands_back_the_rest() {
        engine.enqueue(reply("a", passages: ["One.", "Two.", "Three."]), now: now)
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        away = false                               // the user is back
        XCTAssertEqual(tick(busy: true), [], "the current passage is not cut")
        away = true                                // glancing away again doesn't resume
        engine.progress(position: 10, duration: 10)
        _ = tick(busy: false)
        XCTAssertEqual(tick(busy: false, advance: AutoReadEngine.settleSeconds),
                       [.partlyHeard(itemId: "a", rest: "Two.\n\nThree.")])
        XCTAssertFalse(engine.hasWork)
    }

    func test_returning_between_passages_hands_back_the_rest() {
        engine.enqueue(reply("a", passages: ["One.", "Two."]), now: now)
        _ = tick()
        _ = playActivePassageToEnd()
        away = false
        XCTAssertEqual(tick(), [.partlyHeard(itemId: "a", rest: "Two.")])
    }

    func test_queued_jobs_never_started_stay_as_cards_when_the_user_returns() {
        engine.enqueue(reply("a"), now: now)
        engine.enqueue(reply("b"), now: now)
        away = false
        XCTAssertEqual(tick(busy: true), [])
        XCTAssertFalse(engine.hasWork)
    }

    func test_last_passage_finished_after_return_counts_as_heard_in_full() {
        engine.enqueue(reply("a"), now: now)
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        away = false
        _ = tick(busy: true)
        engine.progress(position: 10, duration: 10)
        _ = tick(busy: false)
        XCTAssertEqual(tick(busy: false, advance: AutoReadEngine.settleSeconds), [.heardInFull(itemId: "a")])
    }

    func test_desk_alert_speaks_while_present_but_still_waits_for_the_user_read() {
        engine.enqueue(alert("a", requiresAway: false), now: now)
        away = false
        XCTAssertEqual(tick(busy: true), [])
        XCTAssertEqual(spoken(tick()), ["s needs you"])
        // Alerts never touch the registry: they stay on screen.
        XCTAssertEqual(playActivePassageToEnd(), [])
    }

    // MARK: call hold

    func test_nothing_starts_while_the_microphone_is_in_use() {
        engine.enqueue(reply("a"), now: now)
        XCTAssertEqual(tick(call: true), [])
        XCTAssertEqual(tick(call: true, advance: 120), [])
        XCTAssertEqual(spoken(tick(call: false)).count, 1)
    }

    func test_call_starting_mid_passage_stops_it_and_repeats_it_afterwards() {
        engine.enqueue(reply("a", session: "myna", passages: ["One.", "Two."]), now: now)
        _ = tick()
        XCTAssertEqual(engine.readStarted(), [])
        XCTAssertEqual(tick(busy: true, call: true), [.stopOwnRead])
        XCTAssertEqual(tick(busy: false, call: true), [])
        XCTAssertEqual(spoken(tick(call: false)), ["From myna. One."])
    }

    // MARK: registry sync and idle alerts

    func test_retain_drops_jobs_that_left_the_pending_list() {
        engine.enqueue(reply("a"), now: now)
        engine.enqueue(reply("b"), now: now)
        engine.retain(pendingIds: ["b"])
        XCTAssertEqual(engine.queue.map(\.itemId), ["b"])
    }

    func test_idle_alert_is_quiet_after_that_sessions_reply_was_read() {
        engine.enqueue(reply("r", session: "myna"), now: now)
        XCTAssertFalse(engine.enqueue(alert("i1", session: "myna", idle: true), now: now), "reply queued")
        _ = tick()
        XCTAssertFalse(engine.enqueue(alert("i2", session: "myna", idle: true), now: now), "reply playing")
        _ = playActivePassageToEnd()
        XCTAssertFalse(engine.enqueue(alert("i3", session: "myna", idle: true), now: now), "just heard")
        // Other sessions and permission prompts are unaffected.
        XCTAssertTrue(engine.enqueue(alert("i4", session: "gala", idle: true), now: now))
        XCTAssertTrue(engine.enqueue(alert("p1", session: "myna", idle: false), now: now))
        now = now.addingTimeInterval(AutoReadEngine.idleAlertQuietPeriod + 1)
        XCTAssertTrue(engine.enqueue(alert("i5", session: "myna", idle: true), now: now))
    }
}
