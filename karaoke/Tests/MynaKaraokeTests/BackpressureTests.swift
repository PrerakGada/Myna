// BackpressureTests.swift — single-slot mailbox semantics.

import XCTest
@testable import MynaKaraokeCore

final class BackpressureTests: XCTestCase {

    func test_emptyMailbox_drainReturnsNothing() {
        let mailbox = Mailbox()
        XCTAssertEqual(mailbox.drain().count, 0)
        XCTAssertNil(mailbox.pendingWord)
        XCTAssertEqual(mailbox.pendingControlCount, 0)
    }

    func test_wordEvents_coalesceToLatest() {
        let mailbox = Mailbox()
        for i in 0..<10 {
            mailbox.submit(.word(WordMessage(id: "u", i: i, tMs: i * 100)))
        }
        XCTAssertNotNil(mailbox.pendingWord)
        XCTAssertEqual(mailbox.pendingWord?.i, 9)
        XCTAssertEqual(mailbox.pendingControlCount, 0)

        let drained = mailbox.drain()
        XCTAssertEqual(drained.count, 1)
        if case .word(let word) = drained[0] {
            XCTAssertEqual(word.i, 9)
        } else {
            XCTFail("expected .word in drain")
        }
        XCTAssertNil(mailbox.pendingWord)
    }

    func test_controlEvents_neverDrop() {
        let mailbox = Mailbox()
        mailbox.submit(.start(StartMessage(
            id: "u",
            sentence: "hi",
            words: [.init(i: 0, t: "hi")],
            estimatedDurationMs: 100,
            voice: "af_heart"
        )))
        mailbox.submit(.pause(PauseMessage(id: "u")))
        mailbox.submit(.resume(ResumeMessage(id: "u", tMs: 50)))
        mailbox.submit(.stop(StopMessage(id: "u")))

        XCTAssertEqual(mailbox.pendingControlCount, 4)
        let drained = mailbox.drain()
        XCTAssertEqual(drained.count, 4)
        // FIFO order preserved.
        if case .start = drained[0] {} else { XCTFail("expected .start first") }
        if case .pause = drained[1] {} else { XCTFail("expected .pause second") }
        if case .resume = drained[2] {} else { XCTFail("expected .resume third") }
        if case .stop = drained[3] {} else { XCTFail("expected .stop fourth") }
    }

    func test_drainOrder_controlThenLatestWord() {
        let mailbox = Mailbox()
        mailbox.submit(.start(StartMessage(
            id: "u",
            sentence: "hi there",
            words: [.init(i: 0, t: "hi"), .init(i: 1, t: "there")],
            estimatedDurationMs: 200,
            voice: "af_heart"
        )))
        mailbox.submit(.word(WordMessage(id: "u", i: 0, tMs: 0)))
        mailbox.submit(.word(WordMessage(id: "u", i: 1, tMs: 100)))
        mailbox.submit(.stop(StopMessage(id: "u")))

        let drained = mailbox.drain()
        // start, stop in FIFO; then the latest word.
        XCTAssertEqual(drained.count, 3)
        if case .start = drained[0] {} else { XCTFail("expected .start first") }
        if case .stop = drained[1] {} else { XCTFail("expected .stop second") }
        if case .word(let word) = drained[2] {
            XCTAssertEqual(word.i, 1, "word should be the latest, not the first")
        } else {
            XCTFail("expected .word last")
        }
    }

    func test_drainResetsState() {
        let mailbox = Mailbox()
        mailbox.submit(.word(WordMessage(id: "u", i: 5, tMs: 100)))
        mailbox.submit(.stop(StopMessage(id: "u")))
        _ = mailbox.drain()
        XCTAssertNil(mailbox.pendingWord)
        XCTAssertEqual(mailbox.pendingControlCount, 0)
        XCTAssertEqual(mailbox.drain().count, 0)
    }

    // MARK: - Concurrency

    func test_concurrentSubmits_singleWordWinner() {
        let mailbox = Mailbox()
        let group = DispatchGroup()
        let writeCount = 200

        for i in 0..<writeCount {
            DispatchQueue.global().async(group: group) {
                mailbox.submit(.word(WordMessage(id: "u", i: i, tMs: i)))
            }
        }
        group.wait()

        let drained = mailbox.drain()
        // After concurrent writes settle, exactly one word remains.
        let words = drained.compactMap { msg -> WordMessage? in
            if case .word(let word) = msg { return word } else { return nil }
        }
        XCTAssertEqual(words.count, 1, "single-slot mailbox should collapse to one word")
    }
}
