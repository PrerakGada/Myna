// SentenceSplitter.swift — cuts one chunk of spoken text into sentences.
//
// The transcript panel lights one sentence at a time and lets the user click
// a sentence to play from it, so its unit is the sentence, not the word. The
// daemon's own chunker splits on a bare `[.!?]` + space, which is fine for
// sizing synthesis work but would cut "Dr. Smith" in two. This splitter is
// stricter. It sees one chunk at a time; Transcript asks it again across a
// chunk boundary to re-join a sentence the daemon cut ("Dr." | "Smith…").
//
// A sentence ends after `.`, `!`, `?` or `…` (runs such as "?!" or "..."
// count as one), plus any closing quotes or brackets, when whitespace
// follows and the next word does not start in lower case. That one rule
// keeps `"Why?" she asked.` and "Wait... what?" whole. On top of it:
//   - a period after a title or common abbreviation ("Dr.", "e.g.", "vs.")
//     never ends a sentence; after "No.", "Fig.", "Jan." and friends it
//     doesn't when a number follows
//   - a period after a capital initial ("J.", "U.S.") doesn't, except "I."
//   - "3.5", "example.com" and "v1.2" never qualify: no whitespace follows
//   - `。！？｡` end a sentence with no whitespace needed (CJK), unless a
//     closing bracket follows (the quote goes on); a line break always ends
//     one (headings and list items carry no full stop)
//
// Whitespace inside a sentence is collapsed for display. Nothing else is
// dropped: the sentences, joined, hold every non-space character of the input.
import Foundation

public enum SentenceSplitter {
    public static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0

        func emit(upTo end: Int, resumeAt next: Int) {
            if end > start {
                let piece = collapsingWhitespace(String(chars[start..<end]))
                if !piece.isEmpty { sentences.append(piece) }
            }
            start = next
        }

        while index < chars.count {
            let char = chars[index]
            if char.isNewline {
                emit(upTo: index, resumeAt: index + 1)
                index += 1
            } else if cjkTerminators.contains(char) {
                var end = index + 1
                while end < chars.count, cjkTerminators.contains(chars[end]) { end += 1 }
                // 「はい。」と言った。 is one sentence: a full stop inside
                // brackets or quotes ends the quote, not the sentence.
                if end < chars.count, closers.contains(chars[end]) {
                    index = end
                } else {
                    emit(upTo: end, resumeAt: end)
                    index = end
                }
            } else if terminators.contains(char) {
                index = endOfTerminator(chars, at: index, emit: emit)
            } else {
                index += 1
            }
        }
        emit(upTo: chars.count, resumeAt: chars.count)
        return sentences
    }

    // MARK: - internals

    static let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
    static let cjkTerminators: Set<Character> = ["\u{3002}", "\u{FF01}", "\u{FF1F}", "\u{FF61}"]
    static let closers: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", "\u{00BB}", "\u{203A}",
        "\u{300D}", "\u{300F}", "\u{FF09}", "\u{3011}", "\u{3009}", "\u{300B}",
    ]

    /// Never end a sentence, whatever follows (lower-cased, inner dots kept).
    static let titles: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "st", "rev", "fr", "gen", "col", "capt", "lt",
        "sgt", "gov", "sen", "rep", "hon", "pres", "mt", "e.g", "i.e", "cf", "vs", "viz",
        "approx", "dept", "est",
    ]
    /// Don't end a sentence when a number follows ("No. 5", "Jan. 12").
    static let beforeNumber: Set<String> = [
        "no", "nos", "vol", "vols", "fig", "figs", "eq", "eqs", "p", "pp", "ch", "sec", "art",
        "ref", "op", "pt", "v", "ver", "ca", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
        "sep", "sept", "oct", "nov", "dec",
    ]

    /// Handle a terminator starting at `index`; returns where scanning resumes.
    private static func endOfTerminator(
        _ chars: [Character], at index: Int, emit: (Int, Int) -> Void
    ) -> Int {
        var end = index + 1
        while end < chars.count, terminators.contains(chars[end]) { end += 1 }
        let terminatorEnd = end
        while end < chars.count, closers.contains(chars[end]) { end += 1 }
        // End of text (the final emit takes it) or glued to the next word
        // ("3.5", "example.com"): not a boundary.
        guard end < chars.count, chars[end].isWhitespace else { return end }
        var next = end
        while next < chars.count, chars[next].isWhitespace, !chars[next].isNewline { next += 1 }
        guard next < chars.count, !chars[next].isNewline else { return end }
        if isBoundary(chars, terminator: index..<terminatorEnd, next: chars[next]) {
            emit(end, end)
        }
        return end
    }

    private static func isBoundary(_ chars: [Character], terminator: Range<Int>, next: Character) -> Bool {
        if next.isLowercase { return false }
        // Only a single full stop can be an abbreviation's; "?", "!", "…"
        // and runs like "..." are always real ends.
        guard terminator.count == 1, chars[terminator.lowerBound] == "." else { return true }
        let word = wordBefore(chars, index: terminator.lowerBound)
        let key = word.lowercased()
        if titles.contains(key) { return false }
        if next.isNumber, beforeNumber.contains(key) { return false }
        if isInitials(word) { return false }
        return true
    }

    /// Letters (and inner dots, for "e.g" and "U.S") right before `index`.
    private static func wordBefore(_ chars: [Character], index: Int) -> String {
        var begin = index
        while begin > 0, chars[begin - 1].isLetter || chars[begin - 1] == "." { begin -= 1 }
        return String(chars[begin..<index])
    }

    /// "J", "U.S", "J.R.R": capital single letters, optionally dotted.
    /// "I" alone is the pronoun, so "…than I. Then" still splits.
    private static func isInitials(_ word: String) -> Bool {
        guard word != "I" else { return false }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { $0.count == 1 && $0.first?.isUppercase == true }
    }

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
