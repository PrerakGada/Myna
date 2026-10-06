// Transcript.swift — the text of one read, as sentences placed on its audio.
//
// Built chunk by chunk as the audio reaches the player: AppDispatcher hands
// each chunk's spoken text and duration over right after it enqueues the
// buffer. So the chunk indices here are the player's, a sentence is only
// ever shown once its audio is in the player, and a chunk that fails to
// decode (skipped by the player) is skipped here too.
//
// A read restarted from a sentence (see TranscriptNavigation) keeps the
// sentences before that point as "carried": shown, but with no place in the
// new read's audio, so playing one restarts the read again from there.
//
// Everything in this file is a value type with no side effects, which is
// what TranscriptTests pins.
import Foundation

/// Where a sentence starts in the read's audio.
public struct SentenceAnchor: Equatable, Sendable {
    /// The player's chunk index.
    public let chunk: Int
    /// Seconds into that chunk (estimated, except 0, which is exact).
    public let offset: TimeInterval
    /// Seconds from the start of the read: the chunk's exact start + offset.
    public let start: TimeInterval
}

public struct TranscriptSentence: Identifiable, Equatable, Sendable {
    /// Position in the transcript. Stable for the life of the transcript.
    public let id: Int
    public fileprivate(set) var text: String
    /// Nil for a sentence carried over from before a restart.
    public let anchor: SentenceAnchor?
}

public struct Transcript: Equatable, Sendable {
    public enum Ending: Equatable, Sendable {
        /// Played to the end.
        case finished
        /// Stopped, skipped or replaced before the end.
        case stopped
    }

    public let readID: UUID
    public let title: String
    public let source: ReadSource
    public let appBundleId: String?
    public let appName: String?
    public private(set) var sentences: [TranscriptSentence] = []
    /// Chunks appended so far, i.e. chunks the player holds for this read.
    public private(set) var chunkCount = 0
    /// Seconds of audio appended so far.
    public private(set) var audioDuration: TimeInterval = 0
    /// Some chunk came without its full text (an older daemon), so the
    /// transcript holds only the first 200 characters of that chunk.
    public private(set) var isPartial = false
    /// Every chunk has been synthesized (or synthesis gave up).
    public var synthesisDone = false
    /// Set once the read is no longer playing.
    public var ending: Ending?

    /// A chunk's last sentence this short or shorter may be joined with the
    /// next chunk's first. The daemon cuts its first chunk short for fast
    /// first audio, at a comma ("Hello world,") or after a bare full stop
    /// ("Dr."), and those halves belong together. A long piece is a hard
    /// split of text with no punctuation; joining it would make one huge
    /// "sentence".
    static let joinLimit = 240

    public init(
        readID: UUID, title: String, source: ReadSource,
        appBundleId: String? = nil, appName: String? = nil
    ) {
        self.readID = readID
        self.title = title
        self.source = source
        self.appBundleId = appBundleId
        self.appName = appName
    }

    /// Title for a read: the article's host, or the text's opening words.
    /// Same rule as the dispatcher's recents title.
    public static func title(for read: QueuedRead) -> String {
        if let url = read.url { return URL(string: url)?.host ?? url }
        let text = SentenceSplitter.collapsingWhitespace(read.text ?? "")
        guard !text.isEmpty else { return "Untitled read" }
        return text.count > 60 ? String(text.prefix(60)) + "\u{2026}" : text
    }

    // MARK: - building

    /// Add the next chunk the player received.
    public mutating func appendChunk(text: String, duration: TimeInterval, isPreviewOnly: Bool = false) {
        let chunk = chunkCount
        let chunkStart = audioDuration
        chunkCount += 1
        // Same left fold as PlaybackQueue.totalDuration, so the two agree.
        audioDuration = chunkStart + duration
        if isPreviewOnly { isPartial = true }

        let pieces = SentenceSplitter.split(text)
        guard !pieces.isEmpty else { return }
        let offsets = SentenceTiming.starts(for: pieces, chunkDuration: duration)
        var first = 0
        // Join across the chunk boundary when the splitter, seeing both
        // sides, finds no sentence end there. Never onto a carried sentence:
        // that one has no audio in this read.
        if let last = sentences.last, last.anchor != nil, last.text.count <= Self.joinLimit {
            let joined = SentenceSplitter.split(Self.join(last.text, pieces[0]))
            if joined.count == 1 {
                sentences[sentences.count - 1].text = joined[0]
                first = 1
            }
        }
        for index in first..<pieces.count {
            let anchor = SentenceAnchor(chunk: chunk, offset: offsets[index], start: chunkStart + offsets[index])
            sentences.append(TranscriptSentence(id: sentences.count, text: pieces[index], anchor: anchor))
        }
    }

    /// A transcript for `readID`, restarting this one at sentence `index`:
    /// sentences before it are carried over, the rest arrive with the audio.
    public func continuation(readID: UUID, from index: Int) -> Transcript {
        var next = Transcript(
            readID: readID, title: title, source: source, appBundleId: appBundleId, appName: appName)
        next.isPartial = isPartial
        next.sentences = sentences.prefix(max(0, min(index, sentences.count))).map {
            TranscriptSentence(id: $0.id, text: $0.text, anchor: nil)
        }
        return next
    }

    // MARK: - reading

    /// The text from sentence `index` to the end, for restarting the read.
    public func remainingText(from index: Int) -> String {
        guard index >= 0, index < sentences.count else { return "" }
        return sentences[index...].map(\.text).joined(separator: " ")
    }

    /// Rough word count, for "automatically for reads longer than N words".
    /// CJK scripts don't space their words; two characters count as one.
    public var wordCount: Int {
        sentences.reduce(0) { total, sentence in
            var words = 0
            var cjk = 0
            for token in sentence.text.split(whereSeparator: { $0.isWhitespace }) {
                let scalars = token.unicodeScalars
                cjk += scalars.filter(Self.isCJK).count
                // A token with any other letter or digit is a word; one of
                // only kana/han (and punctuation) is counted by characters.
                if scalars.contains(where: { !Self.isCJK($0) && CharacterSet.alphanumerics.contains($0) }) {
                    words += 1
                }
            }
            return total + words + (cjk + 1) / 2
        }
    }

    /// The sentence playing at `time` (seconds from the read's start): the
    /// last one that has started. Before the first start, the first one.
    /// Nil when no sentence has audio yet.
    public func sentenceIndex(at time: TimeInterval) -> Int? {
        guard let firstTimed = sentences.firstIndex(where: { $0.anchor != nil }) else { return nil }
        var low = firstTimed
        var high = sentences.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if let start = sentences[mid].anchor?.start, start <= time {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    // MARK: - helpers

    private static func join(_ head: String, _ tail: String) -> String {
        guard let end = head.unicodeScalars.last, let begin = tail.unicodeScalars.first else {
            return head + tail
        }
        return isCJK(end) || isCJK(begin) ? head + tail : head + " " + tail
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Kana and Han. Not Hangul: Korean spaces its words.
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
