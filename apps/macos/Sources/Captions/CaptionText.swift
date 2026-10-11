// CaptionText.swift — the pure half of live captions: when each word of a
// chunk is spoken, the sentence a word sits in, and the caption the pill
// shows at a point in a read's audio.
//
// Word times come from the daemon: Kokoro's own duration predictor for its
// English voices, an estimate for everything else (myna/reading.py). Ranges
// count UTF-16 code units, NSString's units, as the daemon sends them, so
// an emoji before a word doesn't shift it.
//
// Value types only, no actor: the live half (LiveCaptions) and the tests
// both call in from wherever they are.
import Foundation

/// One word of a chunk: when it's spoken, in seconds from the start of the
/// chunk's audio, and where it is in the chunk's text.
public struct TimedWord: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    // Plain integers: these types cross actors, and NSRange's Sendable
    // conformance depends on the SDK (CI builds on an older one).
    private let location: Int
    private let length: Int
    public var range: NSRange { NSRange(location: location, length: length) }

    public init(start: TimeInterval, end: TimeInterval, range: NSRange) {
        self.start = start
        self.end = end
        self.location = range.location
        self.length = range.length
    }
}

public enum ChunkWords {
    /// The `X-Chunk-Words` header: `[[start_ms, end_ms, at_start, at_end], ...]`.
    /// A row that doesn't fit is skipped; no header (an older daemon) or a
    /// broken one is no words.
    public static func parse(_ header: String?) -> [TimedWord] {
        guard let data = header?.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[Double]].self, from: data)
        else { return [] }
        return rows.compactMap { row in
            guard row.count == 4, row[2] >= 0, row[3] > row[2] else { return nil }
            return TimedWord(
                start: row[0] / 1000, end: row[1] / 1000,
                range: NSRange(location: Int(row[2]), length: Int(row[3] - row[2])))
        }
    }

    /// The word being spoken `offset` seconds into the chunk: the last one
    /// that has started. Nil before the first.
    public static func index(at offset: TimeInterval, in words: [TimedWord]) -> Int? {
        guard let first = words.first, first.start <= offset else { return nil }
        var low = 0
        var high = words.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if words[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// What the pill shows: one sentence, and the word being spoken in it.
public struct Caption: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The app's own player: hotkey, pill, Dashboard, hands-free reads.
        case app
        /// The daemon's player: Claude Code's Myna controls, the CLI.
        case daemon
    }

    public let text: String
    private let wordSpan: [Int]  // [location, length], or empty: see TimedWord
    public let isPaused: Bool
    public let source: Source

    /// The lit word within `text`; nil when there's no word timing.
    public var word: NSRange? {
        wordSpan.count == 2 ? NSRange(location: wordSpan[0], length: wordSpan[1]) : nil
    }

    public init(text: String, word: NSRange?, isPaused: Bool, source: Source) {
        self.text = text
        self.wordSpan = word.map { [$0.location, $0.length] } ?? []
        self.isPaused = isPaused
        self.source = source
    }
}

public enum CaptionText {
    /// How much of a long sentence to keep either side of the word, in
    /// UTF-16 units. About three lines of the caption card all told.
    public static let reach = 140

    /// The sentence of `text` holding `range`, cut to `reach` either side
    /// of it with "…", and where `range` is in what comes back.
    public static func sentence(
        around range: NSRange, in text: String, reach: Int = reach
    ) -> (text: String, word: NSRange) {
        let units = Array(text.utf16)
        let count = units.count
        let a = max(0, min(range.location, count))
        let b = max(a, min(NSMaxRange(range), count))
        var start = 0
        var end = count
        for boundary in boundaries(units) {
            if boundary.upperBound <= a {
                start = boundary.upperBound
            } else if boundary.lowerBound >= b {
                end = boundary.lowerBound + punctuationLength(units, from: boundary.lowerBound, to: boundary.upperBound)
                break
            }
        }
        while start < a, isSpace(units[start]) { start += 1 }
        while end > b, isSpace(units[end - 1]) { end -= 1 }
        var prefix = ""
        var suffix = ""
        if a - start > reach {
            let from = a - reach
            start = (from..<a).first { isSpace(units[$0]) }.map { $0 + 1 } ?? from
            prefix = "\u{2026}"
        }
        if end - b > reach {
            let to = b + reach
            end = (b..<to).last { isSpace(units[$0]) } ?? to
            suffix = "\u{2026}"
        }
        let body = String(decoding: units[start..<end], as: UTF16.self)
        let shift = (prefix as NSString).length - start
        return (prefix + body + suffix, NSRange(location: a + shift, length: b - a))
    }

    /// The sentence at `fraction` (0…1) of the way through `text`: what a
    /// chunk without word times shows, unlit.
    public static func sentence(atFraction fraction: Double, in text: String) -> String {
        let length = (text as NSString).length
        let point = Int((max(0, min(1, fraction)) * Double(length)).rounded(.down))
        return sentence(around: NSRange(location: min(point, length), length: 0), in: text).text
    }

    // MARK: - sentence ends

    /// Where sentences end: a run of . ! ? … (then any closing quotes or
    /// brackets) followed by white space, or a line break. Each range runs
    /// from the punctuation to the start of the next sentence.
    static func boundaries(_ u: [UInt16]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = 0
        while i < u.count {
            if isNewline(u[i]) {
                var j = i
                while j < u.count, isSpace(u[j]) { j += 1 }
                out.append(i..<j)
                i = j
                continue
            }
            guard isTerminal(u[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < u.count, isTerminal(u[j]) { j += 1 }
            while j < u.count, isCloser(u[j]) { j += 1 }
            if j < u.count, isSpace(u[j]) {
                var k = j
                while k < u.count, isSpace(u[k]) { k += 1 }
                out.append(i..<k)
                i = k
            } else {
                i = j
            }
        }
        return out
    }

    /// The punctuation (and closers) that open a boundary, which stay with
    /// the sentence before it.
    private static func punctuationLength(_ u: [UInt16], from: Int, to: Int) -> Int {
        var n = 0
        while from + n < to, !isSpace(u[from + n]) { n += 1 }
        return n
    }

    private static func isTerminal(_ c: UInt16) -> Bool {
        c == 0x2E || c == 0x21 || c == 0x3F || c == 0x2026  // . ! ? …
    }

    private static func isCloser(_ c: UInt16) -> Bool {
        // " ' ) ] ” ’
        c == 0x22 || c == 0x27 || c == 0x29 || c == 0x5D || c == 0x201D || c == 0x2019
    }

    private static func isNewline(_ c: UInt16) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
    }

    private static func isSpace(_ c: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }  // a surrogate half
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// The app's own read, chunk by chunk as its audio reaches the player, and
/// the caption at a point in it. Chunk order is the player's (the
/// dispatcher feeds both in the same order), so a position on the player's
/// timeline finds its chunk by adding up durations.
public struct CaptionTimeline: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public let text: String
        public let words: [TimedWord]
        /// Seconds from the read's start, exact (the WAV lengths).
        public let start: TimeInterval
        public let duration: TimeInterval
    }

    /// Lights a word this much early: the player publishes its position
    /// every 50 ms, and a highlight a beat early reads better than late.
    public static let lead: TimeInterval = 0.06

    public let readID: UUID
    public private(set) var chunks: [Chunk] = []
    public private(set) var total: TimeInterval = 0

    public init(readID: UUID) {
        self.readID = readID
    }

    public mutating func append(text: String, words: [TimedWord], duration: TimeInterval) {
        chunks.append(Chunk(text: text, words: words, start: total, duration: duration))
        total += duration
    }

    /// The caption `position` seconds into the read; nil before any audio.
    public func caption(at position: TimeInterval, isPaused: Bool) -> Caption? {
        guard let chunk = chunks.last(where: { $0.start <= position }) ?? chunks.first,
              !chunk.text.isEmpty
        else { return nil }
        let offset = max(0, position - chunk.start) + Self.lead
        if let first = chunk.words.first {
            guard let index = ChunkWords.index(at: offset, in: chunk.words) else {
                // Before the chunk's first word: its sentence, nothing lit yet.
                let line = CaptionText.sentence(around: first.range, in: chunk.text)
                return Caption(text: line.text, word: nil, isPaused: isPaused, source: .app)
            }
            let line = CaptionText.sentence(around: chunk.words[index].range, in: chunk.text)
            return Caption(text: line.text, word: line.word, isPaused: isPaused, source: .app)
        }
        let fraction = chunk.duration > 0 ? offset / chunk.duration : 0
        let text = CaptionText.sentence(atFraction: fraction, in: chunk.text)
        return Caption(text: text, word: nil, isPaused: isPaused, source: .app)
    }
}
