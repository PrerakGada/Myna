// ReadEventTests.swift — the record's own invariants.
//
// The decoding tests matter more than they look: a decode failure throws
// away the user's entire reading history (HistoryStore moves the file
// aside and starts empty), so every field has to survive a file written
// by an older or newer build.
import XCTest

@testable import Myna

final class ReadEventTests: XCTestCase {

    // MARK: - construction

    func testStoredTextIsCappedNotRejected() {
        let long = String(repeating: "a", count: ReadEvent.maxStoredText + 5_000)
        let event = ReadEvent(title: "Long", text: long, voice: "af_heart")
        XCTAssertEqual(event.text?.count, ReadEvent.maxStoredText)
    }

    func testWordCountSplitsOnAllWhitespace() {
        XCTAssertEqual(ReadEvent.wordCount(of: ""), 0)
        XCTAssertEqual(ReadEvent.wordCount(of: "   "), 0)
        XCTAssertEqual(ReadEvent.wordCount(of: "one"), 1)
        XCTAssertEqual(ReadEvent.wordCount(of: "one two  three"), 3)
        XCTAssertEqual(ReadEvent.wordCount(of: "line\nbreak\tand tab"), 4)
    }

    func testTruncatedTitleFlattensNewlines() {
        let event = ReadEvent(title: "first line\nsecond line", voice: "af_heart")
        XCTAssertEqual(event.truncatedTitle(), "first line second line")
    }

    func testTruncatedTitleAddsEllipsisOnlyWhenNeeded() {
        let short = ReadEvent(title: "short", voice: "af_heart")
        XCTAssertEqual(short.truncatedTitle(maxLength: 10), "short")
        let long = ReadEvent(title: String(repeating: "x", count: 50), voice: "af_heart")
        XCTAssertEqual(long.truncatedTitle(maxLength: 10).count, 11)
        XCTAssertTrue(long.truncatedTitle(maxLength: 10).hasSuffix("…"))
    }

    // MARK: - derived values

    func testCompletionFractionIsNilWithoutAudio() {
        let event = ReadEvent(title: "Failed", voice: "af_heart")
        XCTAssertNil(event.completionFraction)
    }

    func testCompletionFractionClampsToOne() {
        var event = ReadEvent(title: "Read", voice: "af_heart")
        event.audioSeconds = 100
        event.listenedSeconds = 130  // seek-past-end and rounding can exceed it
        XCTAssertEqual(try XCTUnwrap(event.completionFraction), 1.0, accuracy: 0.0001)
    }

    func testElapsedSecondsIsNilWhileReading() {
        var event = ReadEvent(title: "Live", voice: "af_heart")
        XCTAssertNil(event.elapsedSeconds)
        event.endedAtMs = event.startedAtMs + 5_000
        XCTAssertEqual(try XCTUnwrap(event.elapsedSeconds), 5.0, accuracy: 0.0001)
    }

    func testEstimatedSilentReadingSecondsIsZeroForNoWords() {
        XCTAssertEqual(ReadEvent(title: "x", voice: "v").estimatedSilentReadingSeconds, 0)
    }

    // MARK: - codable

    func testRoundTripPreservesEveryField() throws {
        var original = ReadEvent(
            title: "Designing Data-Intensive Applications",
            text: "some text",
            url: "https://example.com/a",
            source: .article,
            mode: "summary",
            voice: "bf_emma",
            speed: 1.25,
            characters: 500,
            words: 90,
            firstAudioMs: 640,
            audioSeconds: 42.5,
            listenedSeconds: 40.0,
            appBundleId: "com.google.Chrome",
            appName: "Google Chrome",
            detectedLang: "fr",
            outcome: .completed,
            errorMessage: nil
        )
        original.endedAtMs = original.startedAtMs + 43_000

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReadEvent.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// A file written by v0.6 must still load after fields are added in a
    /// later release.
    func testDecodingToleratesMissingFields() throws {
        let json = """
        { "id": "abc", "started_at_ms": 1700000000000, "title": "Old record",
          "voice": "af_heart" }
        """
        let event = try JSONDecoder().decode(ReadEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.id, "abc")
        XCTAssertEqual(event.title, "Old record")
        XCTAssertEqual(event.source, .unknown)
        XCTAssertEqual(event.mode, "full")
        XCTAssertEqual(event.speed, 1.0)
        XCTAssertEqual(event.words, 0)
        XCTAssertEqual(event.outcome, .stopped)
    }

    /// And a file written by a NEWER build, carrying a source or outcome
    /// this version has never heard of, must degrade rather than take the
    /// whole history down with it.
    func testUnknownEnumValuesDegradeInsteadOfThrowing() throws {
        let json = """
        [{ "id": "a", "started_at_ms": 1700000000000, "title": "t", "voice": "v",
           "source": "telepathy", "outcome": "levitating" }]
        """
        let events = try JSONDecoder().decode([ReadEvent].self, from: Data(json.utf8))
        XCTAssertEqual(events.first?.source, .unknown)
        XCTAssertEqual(events.first?.outcome, .stopped)
    }

    func testCodingKeysAreSnakeCaseOnDisk() throws {
        let event = ReadEvent(title: "t", voice: "v")
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"started_at_ms\""))
        XCTAssertTrue(json.contains("\"listened_seconds\""))
        XCTAssertFalse(json.contains("\"startedAtMs\""))
    }

    // MARK: - presentation

    func testEverySourceHasALabelAndSymbol() {
        for source in ReadSource.allCases {
            XCTAssertFalse(source.label.isEmpty, "\(source) has no label")
            XCTAssertFalse(source.systemImage.isEmpty, "\(source) has no symbol")
        }
    }

    func testOnlyReadingIsNonTerminal() {
        XCTAssertFalse(ReadOutcome.reading.isTerminal)
        for outcome in ReadOutcome.allCases where outcome != .reading {
            XCTAssertTrue(outcome.isTerminal)
        }
    }
}
