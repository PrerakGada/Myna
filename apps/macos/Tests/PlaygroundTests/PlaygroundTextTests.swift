// PlaygroundTextTests.swift — counts, the spoken-length estimate, the
// clock, default filenames and Markdown flattening.
import XCTest

@testable import Myna

final class PlaygroundTextTests: XCTestCase {

    // MARK: - counts

    func testWordCountIgnoresPunctuationOnlyTokens() {
        XCTAssertEqual(PlaygroundText.wordCount(""), 0)
        XCTAssertEqual(PlaygroundText.wordCount("   \n\t "), 0)
        XCTAssertEqual(PlaygroundText.wordCount("One two  three"), 3)
        XCTAssertEqual(PlaygroundText.wordCount("Wait — what? 42 - ok"), 4)
        XCTAssertEqual(PlaygroundText.wordCount("line one\nline two"), 4)
    }

    func testCharacterCountMatchesPythonLen() {
        // The daemon counts code points; so must the limit check.
        XCTAssertEqual(PlaygroundText.characterCount("abc"), 3)
        XCTAssertEqual(PlaygroundText.characterCount("café"), 4)
        XCTAssertEqual(PlaygroundText.characterCount("👍🏽"), 2, "one grapheme, two scalars, as Python sees it")
    }

    func testLimitIsInclusive() {
        let atLimit = String(repeating: "a", count: PlaygroundText.syncCharacterLimit)
        XCTAssertFalse(PlaygroundText.stats(for: atLimit, speed: 1).isOverLimit)
        XCTAssertTrue(PlaygroundText.stats(for: atLimit + "b", speed: 1).isOverLimit)
    }

    // MARK: - estimate

    func testEstimatedSeconds() {
        XCTAssertEqual(PlaygroundText.estimatedSeconds(words: 0, speed: 1), 0)
        XCTAssertEqual(PlaygroundText.estimatedSeconds(words: 160, speed: 1), 60, accuracy: 1e-9)
        XCTAssertEqual(PlaygroundText.estimatedSeconds(words: 160, speed: 2), 30, accuracy: 1e-9)
        XCTAssertEqual(PlaygroundText.estimatedSeconds(words: 80, speed: 0.5), 60, accuracy: 1e-9)
        // Clamped to the daemon's range.
        XCTAssertEqual(PlaygroundText.estimatedSeconds(words: 160, speed: 4), 30, accuracy: 1e-9)
        XCTAssertEqual(PlaygroundText.estimatedSeconds(words: 160, speed: 0.1), 120, accuracy: 1e-9)
    }

    func testStatsCombine() {
        let stats = PlaygroundText.stats(for: String(repeating: "word ", count: 320), speed: 1)
        XCTAssertEqual(stats.words, 320)
        XCTAssertEqual(stats.characters, 1_600)
        XCTAssertEqual(stats.estimatedSeconds, 120, accuracy: 1e-9)
        XCTAssertFalse(stats.isEmpty)
        XCTAssertTrue(PlaygroundText.stats(for: " ", speed: 1).isEmpty)
    }

    func testEstimateLabel() {
        XCTAssertEqual(PlaygroundText.estimateLabel(0), "nothing to speak")
        XCTAssertEqual(PlaygroundText.estimateLabel(0.4), "under a second")
        XCTAssertEqual(PlaygroundText.estimateLabel(80), "about 1m 20s")
    }

    func testClock() {
        XCTAssertEqual(PlaygroundText.clock(0), "0:00")
        XCTAssertEqual(PlaygroundText.clock(7.9), "0:07")
        XCTAssertEqual(PlaygroundText.clock(245), "4:05")
        XCTAssertEqual(PlaygroundText.clock(3_729), "1:02:09")
        XCTAssertEqual(PlaygroundText.clock(-3), "0:00")
    }

    func testSpeedAndRenderLabels() {
        XCTAssertEqual(PlaygroundText.speedLabel(1), "1×")
        XCTAssertEqual(PlaygroundText.speedLabel(1.25), "1.25×")
        XCTAssertEqual(PlaygroundText.speedLabel(0.5), "0.5×")
        XCTAssertEqual(PlaygroundText.renderTimeLabel(ms: 420), "420 ms")
        XCTAssertEqual(PlaygroundText.renderTimeLabel(ms: 1_830), "1.8 s")
    }

    // MARK: - filenames

    func testFileNameFromFirstWordsAndVoice() {
        XCTAssertEqual(
            PlaygroundText.defaultFileName(
                text: "The train leaves platform 4 at 7:45 a.m. on Tuesday", voice: "Heart", ext: "wav"),
            "The train leaves platform 4 at - Heart.wav")
    }

    func testFileNameStripsUnsafeCharactersAndTrailingPunctuation() {
        XCTAssertEqual(
            PlaygroundText.defaultFileName(text: "\"Are you coming?\" she asked.", voice: nil, ext: "m4a"),
            "Are you coming she asked.m4a")
        XCTAssertEqual(
            PlaygroundText.defaultFileName(text: "a/b\\c: d*e?", voice: "x|y", ext: ".mp3"),
            "abc de - xy.mp3")
    }

    func testFileNameNeverHiddenOrEmpty() {
        XCTAssertEqual(PlaygroundText.defaultFileName(text: "", voice: nil, ext: "wav"), "Myna take.wav")
        XCTAssertEqual(PlaygroundText.defaultFileName(text: "?!… ::", voice: nil, ext: "wav"), "Myna take.wav")
        XCTAssertEqual(PlaygroundText.defaultFileName(text: ".hidden file", voice: nil, ext: "wav"), "hidden file.wav")
    }

    func testFileNameRespectsMaxLength() {
        let long = "Pneumonoultramicroscopicsilicovolcanoconiosis is a long word indeed"
        let name = PlaygroundText.defaultFileName(text: long, voice: nil, ext: "wav", maxLength: 30)
        XCTAssertEqual(name, "Pneumonoultramicroscopicsilico.wav", "a single overlong word is cut, not dropped")
        let words = PlaygroundText.defaultFileName(text: "one two three four", voice: nil, ext: "wav", maxLength: 9)
        XCTAssertEqual(words, "one two.wav")
    }

    // MARK: - markdown

    func testMarkdownFlattensToSpokenWords() {
        let markdown = """
        # A heading #

        Some **bold** and *italic* and `code` and a [link](https://example.com).

        > A quote
        - first item
        2. second item

        ```swift
        let x = 1
        ```
        ---
        ![alt text](image.png) snake_case_name stays
        """
        let plain = PlaygroundText.plainText(fromMarkdown: markdown)
        XCTAssertEqual(plain, """
        A heading

        Some bold and italic and code and a link.

        A quote
        first item
        second item

        let x = 1
        alt text snake_case_name stays
        """)
    }

    func testSamplesAreShortAndPlain() {
        XCTAssertGreaterThanOrEqual(PlaygroundText.samples.count, 3)
        for sample in PlaygroundText.samples {
            XCTAssertLessThan(sample.text.count, 400, sample.title)
            XCTAssertFalse(PlaygroundText.stats(for: sample.text, speed: 1).isEmpty)
        }
    }
}
