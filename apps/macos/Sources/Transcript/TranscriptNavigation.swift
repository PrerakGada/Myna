// TranscriptNavigation.swift — which sentence a skip lands on, and how to
// get there: seek in the audio the player already holds, or restart the read.
//
// Two ways to play from a sentence:
//
//   seek     The sentence's chunk is in the player, for the read that is
//            playing or paused. AudioPlayer.seek(chunk:offset:) moves within
//            the buffers it has. This is the normal path: the transcript
//            learns a chunk's text only when that chunk's audio has been
//            handed to the player, in seamless and streaming mode alike, so
//            every sentence the panel shows for the current read is seekable.
//   reread   Anything else: the read has finished or was stopped (the player
//            let go of its audio), or the sentence was carried over from
//            before an earlier restart, or — defensively — its chunk isn't in
//            the player after all. The rest of the text from that sentence is
//            submitted as a new play-now read with the same source and app
//            (so the same voice), and the transcript carries on in place.
//
// Pure functions; TranscriptStore applies the result.
import Foundation

public enum TranscriptNavigation {
    /// Back within this many seconds of a sentence's start goes to the
    /// previous sentence instead of restarting this one — a music player's
    /// back button.
    public static let backThreshold: TimeInterval = 1.5
    /// A seek into the middle of a chunk starts this much early. Start times
    /// inside a chunk are estimates; hearing the end of the previous
    /// sentence is better than losing the first word of this one.
    public static let leadIn: TimeInterval = 0.15
    /// The sentence lit at time t is the one playing at t + lookahead. It
    /// is larger than `leadIn`, so a jump lights its target at once.
    public static let lookahead: TimeInterval = 0.2

    public enum Step: Equatable, Sendable {
        case back
        case forward
    }

    /// What the player looks like right now, as far as a jump cares.
    public struct PlayerSnapshot: Equatable, Sendable {
        /// The transcript belongs to the read the queue is playing.
        public var isCurrentRead: Bool
        /// The player is playing or paused (it holds this read's audio).
        public var sessionActive: Bool
        /// Chunks the player holds.
        public var queuedChunkCount: Int

        public init(isCurrentRead: Bool, sessionActive: Bool, queuedChunkCount: Int) {
            self.isCurrentRead = isCurrentRead
            self.sessionActive = sessionActive
            self.queuedChunkCount = queuedChunkCount
        }
    }

    public enum Jump: Equatable, Sendable {
        case seek(chunk: Int, offset: TimeInterval)
        case reread(fromSentence: Int)
    }

    /// The sentence a Back or Forward lands on, or nil when there is none
    /// (Forward on the last sentence; nothing lit).
    ///
    /// - Parameters:
    ///   - current: the lit sentence.
    ///   - elapsed: seconds since that sentence started. Pass `.infinity`
    ///     for a finished read, so Back replays its last sentence.
    public static func target(
        of step: Step, current: Int?, elapsed: TimeInterval, sentenceCount: Int
    ) -> Int? {
        guard let current, current >= 0, current < sentenceCount else { return nil }
        switch step {
        case .back:
            return elapsed < backThreshold && current > 0 ? current - 1 : current
        case .forward:
            return current + 1 < sentenceCount ? current + 1 : nil
        }
    }

    /// How to play from sentence `index`. Nil for an index out of range.
    public static func plan(to index: Int, in transcript: Transcript, player: PlayerSnapshot) -> Jump? {
        guard index >= 0, index < transcript.sentences.count else { return nil }
        if player.isCurrentRead, player.sessionActive,
           let anchor = transcript.sentences[index].anchor,
           anchor.chunk < player.queuedChunkCount {
            // A chunk's first sentence starts exactly at offset 0; keep it
            // exact rather than reaching back into the previous chunk.
            let offset = anchor.offset > 0 ? max(0, anchor.offset - leadIn) : 0
            return .seek(chunk: anchor.chunk, offset: offset)
        }
        return .reread(fromSentence: index)
    }
}
