// TranscriptStore.swift — the transcript of the read Myna is on, kept in
// step with the queue and the player; and the sentence-skip commands.
//
// Inputs:
//   ReadQueue.current       a new read starts → a new transcript (or the
//                           continuation of a restarted one); nil → the last
//                           transcript stays, marked Finished or Stopped
//   AppDispatcher           didEnqueue(readID:chunks:) as each chunk's audio
//                           reaches the player; synthesisDidEnd(readID:)
//   AudioPlayer             position → the lit sentence; state/isLoading →
//                           the panel's status
//
// Everything arrives on the main actor, synchronously: the queue's and the
// player's publishers fire from main-actor code, so no sink here hops or
// runs on another queue (the crash class in macos26-mainactor-callback-trap).
//
// Commands (panel, pill, shortcuts): jump(to:), previousSentence(),
// nextSentence(), togglePlayPause(), stop(). TranscriptNavigation decides
// seek-or-restart; this class carries it out.
import Combine
import Foundation

/// One chunk as it reached the player.
public struct TranscriptChunk: Equatable, Sendable {
    public let text: String
    public let duration: TimeInterval
    /// Came without its full text (an older daemon): `text` is a preview.
    public let previewOnly: Bool

    public init(text: String, duration: TimeInterval, previewOnly: Bool = false) {
        self.text = text
        self.duration = duration
        self.previewOnly = previewOnly
    }
}

@MainActor
public final class TranscriptStore: ObservableObject {
    public static let shared = TranscriptStore()

    public enum Playback: Equatable, Sendable {
        case idle
        case preparing
        case playing
        case paused
    }

    /// The current read's transcript, or the last one's after it ended.
    @Published public private(set) var transcript: Transcript?
    /// The lit sentence. Nil before the first audio and after the read ends.
    @Published public private(set) var currentIndex: Int?
    @Published public private(set) var playback: Playback = .idle
    /// "+2 queued" while reads wait, as every other surface says it.
    @Published public private(set) var queuedLabel: String?

    /// Called when a read is long enough to open the panel by itself.
    public var onAutoOpen: (@MainActor () -> Void)?

    private let queue: ReadQueue
    private let defaults: UserDefaults
    private weak var player: AudioPlayer?
    private var playerSubscriptions = Set<AnyCancellable>()
    private var queueSubscriptions = Set<AnyCancellable>()
    /// A restart submitted by `reread`: when the queue starts `readID`, it
    /// continues `base` from sentence `from`.
    private struct Continuation {
        let readID: UUID
        let base: Transcript
        let from: Int
    }
    private var pendingContinuation: Continuation?
    /// The read the panel already auto-opened for (or was restarted from
    /// one that did), so it never pops up twice for one read.
    private var autoOpenHandled: UUID?
    /// Where the lit sentence was when the read ended, for Back afterwards.
    private var lastLitIndex: Int?
    private let log = Log(.app)

    public init(queue: ReadQueue = .shared, defaults: UserDefaults = .standard) {
        self.queue = queue
        self.defaults = defaults
        // Not `.receive(on:)`: that would defer the switch past the
        // dispatcher's first didEnqueue for the new read. @Published fires
        // in willSet, so use the value passed in, not queue.current.
        queue.$current
            .sink { [weak self] read in self?.queueCurrentChanged(read) }
            .store(in: &queueSubscriptions)
        queue.$items
            .sink { [weak self] items in self?.queuedLabel = ReadQueue.countLabel(for: items.count) }
            .store(in: &queueSubscriptions)
    }

    /// Wire up the app's player. Idempotent.
    public func attach(player: AudioPlayer) {
        guard self.player !== player else { return }
        self.player = player
        playerSubscriptions.removeAll()
        player.$position
            .sink { [weak self] position in self?.positionChanged(position) }
            .store(in: &playerSubscriptions)
        player.$state
            .sink { [weak self, weak player] state in
                self?.refreshPlayback(state: state, loading: player?.isLoading ?? false)
            }
            .store(in: &playerSubscriptions)
        player.$isLoading
            .sink { [weak self, weak player] loading in
                self?.refreshPlayback(state: player?.state ?? .idle, loading: loading)
            }
            .store(in: &playerSubscriptions)
    }

    // MARK: - from the dispatcher

    /// Chunks of read `readID` that were just handed to the player, in order.
    public func didEnqueue(readID: UUID, chunks: [TranscriptChunk]) {
        guard var current = transcript, current.readID == readID, current.ending == nil else { return }
        for chunk in chunks {
            current.appendChunk(text: chunk.text, duration: chunk.duration, isPreviewOnly: chunk.previewOnly)
        }
        transcript = current
        if let position = player?.position { positionChanged(position) }
        considerAutoOpen(current)
    }

    /// Every chunk of `readID` is in (or synthesis gave up).
    public func synthesisDidEnd(readID: UUID) {
        guard transcript?.readID == readID, transcript?.synthesisDone == false else { return }
        transcript?.synthesisDone = true
    }

    // MARK: - commands

    /// Play from sentence `index`: seek if its audio is in the player,
    /// otherwise restart the read from there (TranscriptNavigation).
    public func jump(to index: Int) {
        guard let current = transcript else { return }
        switch TranscriptNavigation.plan(to: index, in: current, player: snapshot(for: current)) {
        case .seek(let chunk, let offset):
            player?.seek(chunk: chunk, offset: offset)
            currentIndex = index
        case .reread(let from):
            reread(current, from: from)
        case nil:
            break
        }
    }

    public func previousSentence() { step(.back) }
    public func nextSentence() { step(.forward) }

    /// Pause or resume; on a finished read, play it again from the top.
    public func togglePlayPause() {
        switch player?.state {
        case .playing: player?.pause()
        case .paused: player?.resume()
        case .idle, nil:
            if let current = transcript, current.ending != nil, !current.sentences.isEmpty {
                reread(current, from: 0)
            }
        }
    }

    /// Stop means everything, as on the pill: the queue hears it from the
    /// player's session end and drops the waiting reads too.
    public func stop() {
        player?.stop()
    }

    // MARK: - internals

    private func step(_ step: TranscriptNavigation.Step) {
        guard let current = transcript, !current.sentences.isEmpty else { return }
        let lit: Int?
        let elapsed: TimeInterval
        if current.ending != nil {
            lit = lastLitIndex ?? current.sentences.count - 1
            elapsed = .infinity
        } else if let index = currentIndex, let start = current.sentences[index].anchor?.start {
            lit = index
            elapsed = (player?.position ?? start) - start
        } else {
            return
        }
        guard let target = TranscriptNavigation.target(
            of: step, current: lit, elapsed: elapsed, sentenceCount: current.sentences.count)
        else { return }
        jump(to: target)
    }

    private func snapshot(for current: Transcript) -> TranscriptNavigation.PlayerSnapshot {
        TranscriptNavigation.PlayerSnapshot(
            isCurrentRead: queue.current?.id == current.readID && current.ending == nil,
            sessionActive: player.map { $0.state != .idle } ?? false,
            queuedChunkCount: player?.queuedChunkCount ?? 0)
    }

    /// Restart from sentence `index` as a new play-now read of the rest of
    /// the text, same source and app (so the same voice). The queue starts
    /// it synchronously, and queueCurrentChanged continues this transcript.
    private func reread(_ current: Transcript, from index: Int) {
        let text = current.remainingText(from: index)
        guard !text.isEmpty else { return }
        let read = QueuedRead(
            text: text, mode: .full, source: current.source,
            appBundleId: current.appBundleId, appName: current.appName)
        pendingContinuation = Continuation(readID: read.id, base: current, from: index)
        log.info("transcript: restarting the read at sentence \(index) (its audio isn't in the player)")
        queue.submit(read, placement: .playNow)
        if pendingContinuation?.readID == read.id { pendingContinuation = nil }
    }

    private func queueCurrentChanged(_ read: QueuedRead?) {
        guard let read else {
            finishCurrent()
            return
        }
        if let current = transcript, current.readID == read.id, current.ending == nil { return }
        let previous = transcript
        if let pending = pendingContinuation, pending.readID == read.id {
            transcript = pending.base.continuation(readID: read.id, from: pending.from)
            if autoOpenHandled == pending.base.readID { autoOpenHandled = read.id }
        } else {
            transcript = Transcript(
                readID: read.id, title: Transcript.title(for: read), source: read.source,
                appBundleId: read.appBundleId, appName: read.appName)
        }
        pendingContinuation = nil
        currentIndex = nil
        lastLitIndex = nil
        if previous?.readID != transcript?.readID { log.info("transcript: following read \(read.id)") }
    }

    /// The queue has nothing playing any more. Finished if the player got
    /// to the end of this read's audio. A drain leaves the player idle with
    /// its position at the end; a Stop has already emptied it (duration 0);
    /// a Skip reaches here before the player is stopped. (Not the player's
    /// sessionEnds: the dispatcher hears that first and ends the read
    /// before this class would learn which kind of end it was.)
    private func finishCurrent() {
        guard var current = transcript, current.ending == nil else { return }
        let reachedEnd = player.map { $0.state == .idle && $0.duration > 0 && $0.position >= $0.duration - 0.05 }
        current.ending = reachedEnd == true ? .finished : .stopped
        current.synthesisDone = true
        lastLitIndex = currentIndex
        transcript = current
        currentIndex = nil
    }

    private func positionChanged(_ position: TimeInterval) {
        guard let current = transcript, current.ending == nil,
              player.map({ $0.state != .idle }) == true else { return }
        let index = current.sentenceIndex(at: position + TranscriptNavigation.lookahead)
        if index != currentIndex { currentIndex = index }
    }

    private func refreshPlayback(state: AudioPlayer.State, loading: Bool) {
        let next: Playback
        switch state {
        case .playing: next = .playing
        case .paused: next = .paused
        case .idle: next = loading ? .preparing : .idle
        }
        if next != playback { playback = next }
    }

    private func considerAutoOpen(_ current: Transcript) {
        guard autoOpenHandled != current.readID,
              TranscriptAutoOpen.shouldOpen(
                wordCount: current.wordCount,
                visibility: TranscriptVisibility.current(defaults),
                threshold: TranscriptAutoOpen.words(defaults))
        else { return }
        autoOpenHandled = current.readID
        onAutoOpen?()
    }

    #if DEBUG
    /// Tests and snapshots: show a transcript without a player or queue.
    func setForTesting(_ transcript: Transcript?, currentIndex: Int?, playback: Playback) {
        self.transcript = transcript
        self.currentIndex = currentIndex
        self.playback = playback
    }
    #endif
}
