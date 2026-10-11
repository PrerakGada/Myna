// LiveCaptions.swift — the caption the pill shows: the sentence Myna is
// reading and the word being spoken, wherever the read came from.
//
// Two sources:
//   the app's player   AppDispatcher hands each chunk over as its audio
//                      reaches the player (TranscriptFeed calls in here with
//                      the chunk's words), and the player's position picks
//                      the word (CaptionTimeline)
//   the daemon's       Claude Code's Myna controls and the CLI play there;
//   player             ReadingFeed follows it word by word
// The app's own read wins while its player is busy.
//
// Everything arrives on the main actor, synchronously, as in
// TranscriptStore: the player's and the feed's publishers fire from
// main-actor code. @Published fires in willSet, so the sinks use the value
// they're handed, never a re-read of the property.
import AVFoundation
import Combine
import Foundation

@MainActor
public final class LiveCaptions: ObservableObject {
    public static let shared = LiveCaptions()

    /// One chunk as it reached the app's player.
    public struct Enqueued: Equatable, Sendable {
        public let text: String
        public let words: [TimedWord]
        public let duration: TimeInterval

        public init(text: String, words: [TimedWord], duration: TimeInterval) {
            self.text = text
            self.words = words
            self.duration = duration
        }
    }

    /// What the pill shows now; nil when nothing is being read.
    @Published public private(set) var caption: Caption?
    /// The daemon's player is reading (or paused mid-read). The pill shows
    /// for it although the app's own player is idle.
    @Published public private(set) var isDaemonReading = false
    /// The daemon's read is paused (the pill's play/pause icon for it).
    @Published public private(set) var isDaemonPaused = false

    private let feed: ReadingFeed
    private weak var player: AudioPlayer?
    private var timeline: CaptionTimeline?
    private var position: TimeInterval = 0
    private var playerState: AudioPlayer.State = .idle
    private var daemon: DaemonReading?
    private var subscriptions = Set<AnyCancellable>()
    private var playerSubscriptions = Set<AnyCancellable>()

    public init(feed: ReadingFeed = .shared) {
        self.feed = feed
        feed.$reading
            .sink { [weak self] reading in
                self?.daemon = reading
                self?.refresh()
            }
            .store(in: &subscriptions)
    }

    /// Follow the app's player, and start the daemon feed. Idempotent.
    public func attach(player: AudioPlayer) {
        feed.start()
        guard self.player !== player else { return }
        self.player = player
        playerSubscriptions.removeAll()
        position = player.position
        playerState = player.state
        player.$position
            .sink { [weak self] position in
                self?.position = position
                self?.refresh()
            }
            .store(in: &playerSubscriptions)
        player.$state
            .sink { [weak self] state in
                self?.playerState = state
                self?.refresh()
            }
            .store(in: &playerSubscriptions)
    }

    /// Chunks of read `readID` just handed to the player, in order: their
    /// spoken text, words and audio length.
    public func didEnqueue(readID: UUID, chunks: [Enqueued]) {
        if timeline?.readID != readID { timeline = CaptionTimeline(readID: readID) }
        for chunk in chunks {
            timeline?.append(text: chunk.text, words: chunk.words, duration: chunk.duration)
        }
        refresh()
    }

    /// Pause or resume the daemon's read (the pill's button when the read
    /// isn't the app's own).
    public func toggleDaemonPause() {
        guard let daemon else { return }
        feed.control(daemon.state == .paused ? .resume : .pause)
    }

    public func stopDaemon() {
        feed.control(.stop)
    }

    private func refresh() {
        let next: Caption?
        if playerState != .idle, let timeline {
            next = timeline.caption(at: position, isPaused: playerState == .paused)
        } else if let daemon, let word = daemon.word, daemon.state != .preparing {
            let line = CaptionText.sentence(around: word, in: daemon.spoken)
            next = Caption(text: line.text, word: line.word, isPaused: daemon.state == .paused, source: .daemon)
        } else {
            next = nil
        }
        if next != caption { caption = next }
        // From the moment it starts, so the pill is up while the first
        // chunk is still being made.
        let reading = daemon != nil
        if reading != isDaemonReading { isDaemonReading = reading }
        let paused = daemon?.state == .paused
        if paused != isDaemonPaused { isDaemonPaused = paused }
    }
}

extension LiveCaptions {
    /// The dispatcher's chunks as LiveCaptions takes them. Durations are
    /// computed exactly as the player's queue does (QueuedChunk).
    func didEnqueue(readID: UUID, chunks: [SynthesizedChunk], buffers: [AVAudioPCMBuffer]) {
        didEnqueue(readID: readID, chunks: zip(chunks, buffers).map { chunk, buffer in
            Enqueued(text: chunk.spokenText, words: chunk.words, duration: QueuedChunk(index: 0, buffer: buffer).duration)
        })
    }
}
