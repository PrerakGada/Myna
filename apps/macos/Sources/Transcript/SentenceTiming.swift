// SentenceTiming.swift — where each sentence starts inside one chunk's audio.
//
// The daemon sends no timings, only each chunk's text and its WAV. The WAV's
// length is exact, so a chunk's start and end are exact on the read's
// timeline; inside a chunk we share the time out by how much there is to say
// in each sentence, with a short pause after every sentence but the last.
// The error stays inside one chunk (≤ 500 characters in seamless mode,
// 1,500 otherwise) and resets at the next, which is plenty for lighting a
// sentence. It is not good enough for words, and the panel doesn't try.
//
// Weights are rough on purpose: a letter counts 1, a gap between words 1, a
// digit 2.5 (numbers are spoken as long words: "1984" is "nineteen eighty
// four"), and a comma, colon, semicolon or dash 2 (the voice pauses briefly).
import Foundation

public enum SentenceTiming {
    /// Seconds of silence assumed after each sentence. Kokoro leaves roughly
    /// this much at a full stop.
    public static let sentencePause: TimeInterval = 0.25
    /// Pauses never take more than this share of a chunk, so a chunk of
    /// one-word sentences still gives each word most of its time.
    public static let maxPauseShare: Double = 0.15

    /// Start of each sentence, in seconds from the start of the chunk. The
    /// first is always 0; the rest increase and stay below `chunkDuration`.
    public static func starts(for sentences: [String], chunkDuration: TimeInterval) -> [TimeInterval] {
        let count = sentences.count
        guard count > 0 else { return [] }
        guard chunkDuration > 0, count > 1 else { return Array(repeating: 0, count: count) }
        let pause = min(sentencePause, chunkDuration * maxPauseShare / Double(count - 1))
        let speech = max(0, chunkDuration - pause * Double(count - 1))
        let weights = sentences.map(weight(of:))
        let total = weights.reduce(0, +)
        var starts: [TimeInterval] = []
        starts.reserveCapacity(count)
        var time: TimeInterval = 0
        for weight in weights {
            starts.append(time)
            time += speech * weight / total + pause
        }
        return starts
    }

    /// How much there is to say in `sentence`, in rough letter units. Never
    /// below 1, so a lone "…" still gets a sliver of time.
    public static func weight(of sentence: String) -> Double {
        var weight = 0.0
        var inWord = false
        for char in sentence {
            if char.isWhitespace {
                if inWord { weight += 1 }
                inWord = false
                continue
            }
            inWord = true
            if char.isNumber {
                weight += 2.5
            } else if char.isLetter {
                weight += 1
            } else if pauseMarks.contains(char) {
                weight += 2
            }
        }
        return max(1, weight)
    }

    private static let pauseMarks: Set<Character> = [",", ";", ":", "\u{2014}", "\u{2013}", "\u{3001}", "\u{FF0C}"]
}
