// CaptionTextTests.swift — live captions' pure half: word times from the
// daemon's header, the sentence a word sits in (UTF-16, so emoji don't
// shift it), and the caption at a point in the app's read.
import XCTest

@testable import Myna

final class CaptionTextTests: XCTestCase {
    private func range(of word: String, in text: String) -> NSRange {
        (text as NSString).range(of: word)
    }

    private func lit(_ caption: Caption?) -> String? {
        guard let caption, let word = caption.word else { return nil }
        return (caption.text as NSString).substring(with: word)
    }

    // MARK: - ChunkWords

    func testParsesTheHeaderAndSkipsRowsThatDontFit() {
        let words = ChunkWords.parse("[[100,400,0,5],[500,700,7,10],[1,2,9,3],[7]]")
        XCTAssertEqual(words, [
            TimedWord(start: 0.1, end: 0.4, range: NSRange(location: 0, length: 5)),
            TimedWord(start: 0.5, end: 0.7, range: NSRange(location: 7, length: 3)),
        ])
        XCTAssertEqual(ChunkWords.parse(nil), [])
        XCTAssertEqual(ChunkWords.parse("not json"), [])
    }

    func testTheWordNowIsTheLastOneStarted() {
        let words = ChunkWords.parse("[[100,400,0,5],[500,700,7,10],[750,1100,11,16]]")
        XCTAssertNil(ChunkWords.index(at: 0.05, in: words))
        XCTAssertEqual(ChunkWords.index(at: 0.1, in: words), 0)
        XCTAssertEqual(ChunkWords.index(at: 0.45, in: words), 0)  // the pause after a word keeps it lit
        XCTAssertEqual(ChunkWords.index(at: 0.6, in: words), 1)
        XCTAssertEqual(ChunkWords.index(at: 9, in: words), 2)
        XCTAssertNil(ChunkWords.index(at: 1, in: []))
    }

    // MARK: - CaptionText

    func testShowsTheWholeSentenceHoldingTheWord() {
        let text = "First one. The button sits outside the row, so it never gets width! Last one?"
        let line = CaptionText.sentence(around: range(of: "outside", in: text), in: text)
        XCTAssertEqual(line.text, "The button sits outside the row, so it never gets width!")
        XCTAssertEqual((line.text as NSString).substring(with: line.word), "outside")
        XCTAssertEqual(CaptionText.sentence(around: range(of: "First", in: text), in: text).text, "First one.")
        XCTAssertEqual(CaptionText.sentence(around: range(of: "Last", in: text), in: text).text, "Last one?")
    }

    func testEmojiAndQuotesDontShiftTheWord() {
        let text = "🎉 Shipped it. He said \u{201C}done.\u{201D} Then 👍🏽 left."
        let shipped = CaptionText.sentence(around: range(of: "Shipped", in: text), in: text)
        XCTAssertEqual(shipped.text, "🎉 Shipped it.")
        XCTAssertEqual((shipped.text as NSString).substring(with: shipped.word), "Shipped")
        let left = CaptionText.sentence(around: range(of: "left", in: text), in: text)
        XCTAssertEqual(left.text, "Then 👍🏽 left.")
        XCTAssertEqual((left.text as NSString).substring(with: left.word), "left")
        let said = CaptionText.sentence(around: range(of: "said", in: text), in: text)
        XCTAssertEqual(said.text, "He said \u{201C}done.\u{201D}")
    }

    func testLineBreaksEndASentenceAndNumbersDont() {
        let text = "Costs $4.99 a month\nSecond line here"
        XCTAssertEqual(CaptionText.sentence(around: range(of: "month", in: text), in: text).text, "Costs $4.99 a month")
        XCTAssertEqual(CaptionText.sentence(around: range(of: "line", in: text), in: text).text, "Second line here")
    }

    func testCutsALongSentenceAroundTheWord() {
        let text = Array(repeating: "word", count: 120).joined(separator: " ") + " target "
            + Array(repeating: "word", count: 120).joined(separator: " ") + "."
        let line = CaptionText.sentence(around: range(of: "target", in: text), in: text, reach: 40)
        XCTAssertTrue(line.text.hasPrefix("\u{2026}"))
        XCTAssertTrue(line.text.hasSuffix("\u{2026}"))
        XCTAssertLessThan((line.text as NSString).length, 100)
        XCTAssertEqual((line.text as NSString).substring(with: line.word), "target")
    }

    func testWithoutWordTimesTheSentenceFollowsTheTime() {
        let text = "One two three. Four five six."
        XCTAssertEqual(CaptionText.sentence(atFraction: 0.1, in: text), "One two three.")
        XCTAssertEqual(CaptionText.sentence(atFraction: 0.9, in: text), "Four five six.")
    }

    // MARK: - CaptionTimeline

    func testTheCaptionFollowsThePlayerAcrossChunks() {
        var timeline = CaptionTimeline(readID: UUID())
        let first = "Hello, big world."
        let second = "Second part here."
        timeline.append(text: first, words: [
            TimedWord(start: 0.2, end: 0.5, range: range(of: "Hello", in: first)),
            TimedWord(start: 0.6, end: 0.8, range: range(of: "big", in: first)),
            TimedWord(start: 0.9, end: 1.2, range: range(of: "world", in: first)),
        ], duration: 1.5)
        timeline.append(text: second, words: [
            TimedWord(start: 0.1, end: 0.4, range: range(of: "Second", in: second)),
            TimedWord(start: 0.5, end: 0.7, range: range(of: "part", in: second)),
        ], duration: 1.0)

        let start = timeline.caption(at: 0, isPaused: false)
        XCTAssertEqual(start?.text, "Hello, big world.")
        XCTAssertNil(start?.word)  // before the first word
        XCTAssertEqual(lit(timeline.caption(at: 0.7, isPaused: false)), "big")
        XCTAssertEqual(lit(timeline.caption(at: 1.45, isPaused: false)), "world")
        let later = timeline.caption(at: 1.5 + 0.55, isPaused: true)
        XCTAssertEqual(later?.text, "Second part here.")
        XCTAssertEqual(lit(later), "part")
        XCTAssertEqual(later?.isPaused, true)
        XCTAssertEqual(later?.source, .app)
    }

    func testAChunkWithoutWordTimesStillShowsItsSentence() {
        var timeline = CaptionTimeline(readID: UUID())
        timeline.append(text: "One two three. Four five six.", words: [], duration: 2)
        XCTAssertEqual(timeline.caption(at: 1.8, isPaused: false)?.text, "Four five six.")
        XCTAssertNil(timeline.caption(at: 1.8, isPaused: false)?.word)
        XCTAssertNil(CaptionTimeline(readID: UUID()).caption(at: 0, isPaused: false))
    }
}
