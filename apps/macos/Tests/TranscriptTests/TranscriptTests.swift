// TranscriptTests.swift — the pure parts of the sentence transcript: the
// splitter, per-chunk timing, the transcript's time map, the back-button
// rule, and the seek-or-restart choice. No audio, no windows.
import XCTest

@testable import Myna

final class TranscriptTests: XCTestCase {

    // MARK: - splitter

    private func split(_ text: String) -> [String] { SentenceSplitter.split(text) }

    func test_splits_plain_sentences() {
        XCTAssertEqual(split("One here. Two there! Three? Four."), ["One here.", "Two there!", "Three?", "Four."])
    }

    func test_titles_and_latin_abbreviations_do_not_end_a_sentence() {
        XCTAssertEqual(
            split("Dr. Smith met Mr. Jones at St. Mary's. They talked."),
            ["Dr. Smith met Mr. Jones at St. Mary's.", "They talked."])
        XCTAssertEqual(
            split("Bring a tool, e.g. A hammer. Or i.e. The small one. Done."),
            ["Bring a tool, e.g. A hammer.", "Or i.e. The small one.", "Done."])
        XCTAssertEqual(split("Cats vs. Dogs is old. Next."), ["Cats vs. Dogs is old.", "Next."])
    }

    func test_ambiguous_abbreviations_end_a_sentence_before_a_capital_only() {
        XCTAssertEqual(split("We met at 5 p.m. and talked."), ["We met at 5 p.m. and talked."])
        XCTAssertEqual(split("We met at 5 p.m. Then we left."), ["We met at 5 p.m.", "Then we left."])
        XCTAssertEqual(split("Apples, pears, etc. are fruit."), ["Apples, pears, etc. are fruit."])
    }

    func test_abbreviations_before_numbers() {
        XCTAssertEqual(split("See No. 5 for details. Fig. 3 shows it."), ["See No. 5 for details.", "Fig. 3 shows it."])
        XCTAssertEqual(split("It cost $5. 3 people came."), ["It cost $5.", "3 people came."])
    }

    func test_decimals_versions_and_domains_never_split() {
        XCTAssertEqual(
            split("It costs 3.5 dollars. Pi is 3.14159! See example.com or v1.2.3 now."),
            ["It costs 3.5 dollars.", "Pi is 3.14159!", "See example.com or v1.2.3 now."])
    }

    func test_ellipses() {
        XCTAssertEqual(
            split("Wait... what happened? I don't know\u{2026} Then she left."),
            ["Wait... what happened?", "I don't know\u{2026}", "Then she left."])
        XCTAssertEqual(split("Well\u{2026} maybe."), ["Well\u{2026} maybe."])
    }

    func test_quotes() {
        XCTAssertEqual(
            split("\"Why?\" she asked. \"Because.\" He shrugged."),
            ["\"Why?\" she asked.", "\"Because.\"", "He shrugged."])
        XCTAssertEqual(
            split("He said \u{201C}Stop.\u{201D} Then he left."),
            ["He said \u{201C}Stop.\u{201D}", "Then he left."])
        XCTAssertEqual(split("(It ended.) New start."), ["(It ended.)", "New start."])
    }

    func test_initials_and_the_pronoun_i() {
        XCTAssertEqual(
            split("J. K. Rowling wrote it. The U.S. Army agreed."),
            ["J. K. Rowling wrote it.", "The U.S. Army agreed."])
        XCTAssertEqual(split("So did I. Then we left."), ["So did I.", "Then we left."])
    }

    func test_line_breaks_always_end_a_sentence() {
        XCTAssertEqual(
            split("Heading\nFirst line. Second line.\n\n- item one\n- item two"),
            ["Heading", "First line.", "Second line.", "- item one", "- item two"])
    }

    func test_whitespace_inside_a_sentence_is_collapsed() {
        XCTAssertEqual(split("  One  two\tthree.   Four.  "), ["One two three.", "Four."])
        XCTAssertEqual(split(" \n\t "), [])
        XCTAssertEqual(split(""), [])
    }

    func test_cjk_punctuation_ends_sentences_without_spaces() {
        XCTAssertEqual(
            split("今日は晴れです。明日は雨でしょう！本当？"),
            ["今日は晴れです。", "明日は雨でしょう！", "本当？"])
        XCTAssertEqual(
            split("「はい。」と言った。これはペンです。 This is English. 你好。"),
            ["「はい。」と言った。", "これはペンです。", "This is English.", "你好。"])
    }

    func test_splitting_drops_nothing_but_whitespace() {
        let inputs = [
            "Dr. Smith said \"hi.\" Then... nothing! 3.5 is e.g. More? Yes.\nNew line",
            "今日は晴れです。「はい。」と言った。Mixed text here. 你好！",
            "No terminator at all",
            "…",
        ]
        for input in inputs {
            let kept = split(input).joined().filter { !$0.isWhitespace }
            XCTAssertEqual(kept, input.filter { !$0.isWhitespace }, input)
        }
    }

    // MARK: - timing within a chunk

    func test_a_lone_sentence_starts_at_zero() {
        XCTAssertEqual(SentenceTiming.starts(for: ["Only one."], chunkDuration: 4), [0])
        XCTAssertEqual(SentenceTiming.starts(for: [], chunkDuration: 4), [])
    }

    func test_time_is_shared_by_weight_with_a_pause_between() {
        let starts = SentenceTiming.starts(for: ["Hi.", "This is a much longer sentence."], chunkDuration: 3)
        // "Hi." weighs 2; the second weighs 25 letters + 5 gaps = 30.
        // Pause 0.25 s; 2.75 s of speech: 2.75 × 2/32 + 0.25.
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0], 0)
        XCTAssertEqual(starts[1], 2.75 * 2 / 32 + 0.25, accuracy: 1e-9)
    }

    func test_starts_rise_and_stay_inside_the_chunk() {
        let sentences = (1...12).map { "Sentence number \($0) says a few words." }
        let starts = SentenceTiming.starts(for: sentences, chunkDuration: 20)
        XCTAssertEqual(starts.count, 12)
        XCTAssertEqual(zip(starts, starts.dropFirst()).filter { $0 >= $1 }.count, 0)
        XCTAssertLessThan(starts.last ?? 99, 20)
    }

    func test_pauses_never_swallow_a_short_chunk() {
        let words = Array(repeating: "Go.", count: 10)
        let starts = SentenceTiming.starts(for: words, chunkDuration: 1)
        // Pauses capped at 15% of the chunk: evenly weighted words stay even.
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        XCTAssertEqual(gaps.max() ?? 0, gaps.min() ?? 1, accuracy: 1e-9)
        XCTAssertLessThan(starts.last ?? 1, 1)
    }

    func test_weights() {
        XCTAssertGreaterThan(SentenceTiming.weight(of: "1984"), SentenceTiming.weight(of: "abcd"))
        XCTAssertGreaterThan(SentenceTiming.weight(of: "one, two"), SentenceTiming.weight(of: "one two"))
        XCTAssertEqual(SentenceTiming.weight(of: "\u{2026}"), 1)
        XCTAssertEqual(SentenceTiming.starts(for: ["A.", "B."], chunkDuration: 0), [0, 0])
    }

    // MARK: - transcript time map

    private func transcript(_ chunks: [(String, TimeInterval)]) -> Transcript {
        var transcript = Transcript(readID: UUID(), title: "T", source: .selection)
        for (text, duration) in chunks { transcript.appendChunk(text: text, duration: duration) }
        return transcript
    }

    func test_chunk_starts_are_exact_on_the_read_timeline() {
        let t = transcript([("Alpha one. Alpha two.", 2.0), ("Beta one. Beta two.", 3.0)])
        XCTAssertEqual(t.sentences.map(\.text), ["Alpha one.", "Alpha two.", "Beta one.", "Beta two."])
        XCTAssertEqual(t.chunkCount, 2)
        XCTAssertEqual(t.audioDuration, 5.0)
        XCTAssertEqual(t.sentences[2].anchor, SentenceAnchor(chunk: 1, offset: 0, start: 2.0))
        XCTAssertEqual(t.sentences[0].anchor?.start, 0)
        XCTAssertEqual(t.sentences.map(\.id), [0, 1, 2, 3])
    }

    func test_sentence_at_time() {
        let t = transcript([("Alpha one. Alpha two.", 2.0), ("Beta one. Beta two.", 3.0)])
        let alphaTwo = t.sentences[1].anchor?.start ?? 0
        XCTAssertEqual(t.sentenceIndex(at: -1), 0)
        XCTAssertEqual(t.sentenceIndex(at: 0), 0)
        XCTAssertEqual(t.sentenceIndex(at: alphaTwo - 0.01), 0)
        XCTAssertEqual(t.sentenceIndex(at: alphaTwo), 1)
        XCTAssertEqual(t.sentenceIndex(at: 1.999), 1)
        XCTAssertEqual(t.sentenceIndex(at: 2.0), 2)
        XCTAssertEqual(t.sentenceIndex(at: 60), 3)
        XCTAssertNil(Transcript(readID: UUID(), title: "", source: .selection).sentenceIndex(at: 1))
    }

    func test_the_daemons_short_first_chunk_is_joined_to_its_sentence() {
        // The daemon cuts a long first sentence at a comma for fast first audio.
        let t = transcript([("Hello world,", 0.8), ("this is the rest of it. Next one.", 3.0)])
        XCTAssertEqual(t.sentences.map(\.text), ["Hello world, this is the rest of it.", "Next one."])
        XCTAssertEqual(t.sentences[0].anchor, SentenceAnchor(chunk: 0, offset: 0, start: 0))
        XCTAssertEqual(t.sentences[1].anchor?.chunk, 1)
    }

    func test_a_first_chunk_cut_after_an_abbreviation_is_joined() {
        // Seen live: the daemon's first-chunk cut stops at any "." + space.
        let t = transcript([("Dr.", 0.4), ("Smith opened the door. Behind it was a corridor.", 4.0)])
        XCTAssertEqual(t.sentences.map(\.text), ["Dr. Smith opened the door.", "Behind it was a corridor."])
        XCTAssertEqual(t.sentences[0].anchor?.chunk, 0)
    }

    func test_a_lowercase_continuation_across_chunks_is_joined() {
        let t = transcript([("First one.", 1.0), ("second starts lower. Then more.", 2.0)])
        // Lower case after a full stop reads as one sentence to the splitter,
        // so this joins; a capital keeps them apart (see the chunk-start test).
        XCTAssertEqual(t.sentences.map(\.text), ["First one. second starts lower.", "Then more."])
    }

    func test_a_long_unpunctuated_piece_is_not_joined() {
        let long = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces)
        let t = transcript([(long, 10), ("more words here. End.", 2)])
        XCTAssertEqual(t.sentences.count, 3)
        XCTAssertEqual(t.sentences[1].text, "more words here.")
    }

    func test_cjk_join_adds_no_space() {
        let t = transcript([("今日は晴れ、", 0.5), ("明日は雨。", 1.0)])
        XCTAssertEqual(t.sentences.map(\.text), ["今日は晴れ、明日は雨。"])
    }

    func test_continuation_carries_earlier_sentences_without_audio() {
        let base = transcript([("One. Two. Three. Four.", 4.0)])
        let nextID = UUID()
        var next = base.continuation(readID: nextID, from: 2)
        XCTAssertEqual(next.readID, nextID)
        XCTAssertEqual(next.title, base.title)
        XCTAssertEqual(next.sentences.map(\.text), ["One.", "Two."])
        XCTAssertTrue(next.sentences.allSatisfy { $0.anchor == nil })
        XCTAssertNil(next.sentenceIndex(at: 0), "no sentence has audio yet")

        next.appendChunk(text: "Three. Four.", duration: 2.0)
        XCTAssertEqual(next.sentences.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(next.sentences[2].anchor, SentenceAnchor(chunk: 0, offset: 0, start: 0))
        XCTAssertEqual(next.sentenceIndex(at: 0), 2, "carried sentences are never lit")
    }

    func test_remaining_text_word_count_and_title() {
        let t = transcript([("One two. Three four five. Six.", 3.0)])
        XCTAssertEqual(t.remainingText(from: 1), "Three four five. Six.")
        XCTAssertEqual(t.remainingText(from: 9), "")
        XCTAssertEqual(t.wordCount, 6)
        XCTAssertEqual(transcript([("今日は晴れです。", 1.0)]).wordCount, 4)

        XCTAssertEqual(Transcript.title(for: QueuedRead(url: "https://example.com/a", source: .article)), "example.com")
        let long = QueuedRead(text: String(repeating: "abc ", count: 30), source: .selection)
        XCTAssertEqual(Transcript.title(for: long).count, 61)
        XCTAssertTrue(Transcript.title(for: long).hasSuffix("\u{2026}"))
    }

    func test_preview_only_chunks_mark_the_transcript_partial() {
        var t = transcript([("Full text.", 1.0)])
        XCTAssertFalse(t.isPartial)
        t.appendChunk(text: "Cut short", duration: 1.0, isPreviewOnly: true)
        XCTAssertTrue(t.isPartial)
        XCTAssertTrue(t.continuation(readID: UUID(), from: 1).isPartial)
    }

    // MARK: - back and forward

    func test_back_restarts_the_sentence_unless_it_just_began() {
        let target = TranscriptNavigation.target
        XCTAssertEqual(target(.back, 3, 2.0, 5), 3, "well into it: back to its start")
        XCTAssertEqual(target(.back, 3, 1.49, 5), 2, "just began: the one before")
        XCTAssertEqual(target(.back, 3, 1.5, 5), 3)
        XCTAssertEqual(target(.back, 0, 0.2, 5), 0, "nothing before the first")
        XCTAssertEqual(target(.back, 4, .infinity, 5), 4, "after the end: the last one again")
        XCTAssertNil(target(.back, nil, 0, 5))
        XCTAssertNil(target(.back, 7, 0, 5))
    }

    func test_forward_stops_at_the_last_sentence() {
        let target = TranscriptNavigation.target
        XCTAssertEqual(target(.forward, 3, 0, 5), 4)
        XCTAssertNil(target(.forward, 4, 0, 5))
        XCTAssertNil(target(.forward, nil, 0, 5))
    }

    // MARK: - seek or restart

    private func playing(chunks: Int, current: Bool = true, active: Bool = true) -> TranscriptNavigation.PlayerSnapshot {
        .init(isCurrentRead: current, sessionActive: active, queuedChunkCount: chunks)
    }

    func test_audio_in_the_player_is_seeked() {
        let t = transcript([("Alpha one. Alpha two.", 2.0), ("Beta one. Beta two.", 3.0)])
        let plan = { TranscriptNavigation.plan(to: $0, in: t, player: $1) }
        XCTAssertEqual(plan(2, playing(chunks: 2)), .seek(chunk: 1, offset: 0), "a chunk's first sentence: exact")
        guard case .seek(let chunk, let offset)? = plan(3, playing(chunks: 2)) else {
            return XCTFail("expected a seek")
        }
        XCTAssertEqual(chunk, 1)
        let estimate = t.sentences[3].anchor?.offset ?? 0
        XCTAssertEqual(offset, estimate - TranscriptNavigation.leadIn, accuracy: 1e-9)
        XCTAssertGreaterThan(TranscriptNavigation.lookahead, TranscriptNavigation.leadIn)
    }

    func test_anything_not_in_the_player_restarts_the_read() {
        let t = transcript([("Alpha one. Alpha two.", 2.0), ("Beta one. Beta two.", 3.0)])
        let plan = { TranscriptNavigation.plan(to: $0, in: t, player: $1) }
        XCTAssertEqual(plan(2, playing(chunks: 1)), .reread(fromSentence: 2), "chunk not in the player yet")
        XCTAssertEqual(plan(0, playing(chunks: 2, current: false)), .reread(fromSentence: 0), "an earlier read")
        XCTAssertEqual(plan(1, playing(chunks: 2, active: false)), .reread(fromSentence: 1), "finished or stopped")
        let carried = t.continuation(readID: UUID(), from: 2)
        XCTAssertEqual(
            TranscriptNavigation.plan(to: 1, in: carried, player: playing(chunks: 2)),
            .reread(fromSentence: 1), "carried over from before a restart")
        XCTAssertNil(plan(9, playing(chunks: 2)))
        XCTAssertNil(plan(-1, playing(chunks: 2)))
    }

    func test_a_tiny_offset_never_seeks_before_the_chunk() {
        var t = Transcript(readID: UUID(), title: "", source: .selection)
        t.appendChunk(text: "Hi. Yo.", duration: 0.1)
        guard case .seek(let chunk, let offset)? = TranscriptNavigation.plan(to: 1, in: t, player: playing(chunks: 1)) else {
            return XCTFail("expected a seek")
        }
        XCTAssertEqual(chunk, 0)
        XCTAssertEqual(offset, 0)
    }

    // MARK: - settings

    func test_auto_open_rule() {
        XCTAssertTrue(TranscriptAutoOpen.shouldOpen(wordCount: 201, visibility: .automatic, threshold: 200))
        XCTAssertFalse(TranscriptAutoOpen.shouldOpen(wordCount: 200, visibility: .automatic, threshold: 200))
        XCTAssertFalse(TranscriptAutoOpen.shouldOpen(wordCount: 5_000, visibility: .onRequest, threshold: 200))
        XCTAssertFalse(TranscriptAutoOpen.shouldOpen(wordCount: 5_000, visibility: .off, threshold: 200))

        let suite = "transcript-settings-\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TranscriptVisibility.current(defaults), .onRequest)
        XCTAssertEqual(TranscriptAutoOpen.words(defaults), 200)
        defaults.set("automatic", forKey: TranscriptVisibility.defaultsKey)
        defaults.set(500, forKey: TranscriptAutoOpen.defaultsKey)
        XCTAssertEqual(TranscriptVisibility.current(defaults), .automatic)
        XCTAssertEqual(TranscriptAutoOpen.words(defaults), 500)
        defaults.set("bogus", forKey: TranscriptVisibility.defaultsKey)
        XCTAssertEqual(TranscriptVisibility.current(defaults), .onRequest)
    }
}
