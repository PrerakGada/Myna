// HistoryRecorder.swift — turns playback into history.
//
// AppDispatcher knows what was requested; AudioPlayer knows what was
// actually heard. Neither alone can write a truthful ReadEvent, so this
// class sits between them:
//
//   dispatcher  ──begin(...)──▶  recorder  ──append──▶  HistoryStore
//                ──noteFirstAudio()──▶│
//                ──noteFailure(...)──▶│
//   AudioPlayer ──$state / $position─▶│──update──▶
//
// The subtle part is "seconds actually listened". AudioPlayer.stop()
// resets `position` to 0 before `state` publishes `.idle`, so sampling
// position at the transition always reads zero. We therefore sample
// continuously while playing and finalize from the last non-zero sample.
import Combine
import Foundation

@MainActor
public final class HistoryRecorder: ObservableObject {

    /// A read is called "completed" when the user heard everything but
    /// the last moment of it — the player's own drain-to-idle can land a
    /// fraction of a second short, and rounding that to "stopped" would
    /// make the completion rate meaningless.
    public static let completionToleranceSeconds: Double = 1.5

    private let store: HistoryStore
    private let player: AudioPlayer
    private var cancellables: Set<AnyCancellable> = []
    private let log = Log(.app)

    /// Event currently being recorded, if any.
    private(set) var activeId: String?
    /// Wall-clock ms the active read was requested at, for latency.
    private var activeStartedAtMs: Int = 0
    /// Highest playback position seen during the active read.
    private var maxPosition: Double = 0
    /// Longest duration the player reported during the active read. The
    /// stream grows this as chunks arrive, so the last value before idle
    /// is the full audio length.
    private var maxDuration: Double = 0

    public init(store: HistoryStore = .shared, player: AudioPlayer) {
        self.store = store
        self.player = player
        observePlayer()
    }

    // MARK: - lifecycle of one read

    /// Everything known about a read at the moment it is requested.
    /// A value type rather than nine parameters so call sites read as
    /// a description of the read instead of a positional argument list.
    public struct Start: Sendable {
        public var title: String
        public var text: String?
        public var url: String?
        public var source: ReadSource
        public var mode: String
        public var voice: String
        public var speed: Double
        public var appBundleId: String?
        public var appName: String?
        /// The text prep sent with the read (TextPrep.rawValue).
        public var prep: String?

        public init(
            title: String,
            text: String? = nil,
            url: String? = nil,
            source: ReadSource,
            mode: String = "full",
            voice: String,
            speed: Double = 1.0,
            appBundleId: String? = nil,
            appName: String? = nil,
            prep: String? = nil
        ) {
            self.title = title
            self.text = text
            self.url = url
            self.source = source
            self.mode = mode
            self.voice = voice
            self.speed = speed
            self.appBundleId = appBundleId
            self.appName = appName
            self.prep = prep
        }
    }

    /// Open a record. Returns its id; the caller keeps it only if it wants
    /// to attach metadata later (the recorder already tracks it).
    @discardableResult
    public func begin(_ start: Start) -> String {
        // A new read supersedes any still-open one. Close it as stopped
        // with whatever was heard, then start fresh.
        finalizeActive(outcome: .stopped)

        let body = start.text ?? ""
        let event = ReadEvent(
            title: start.title,
            text: start.text,
            url: start.url,
            source: start.source,
            mode: start.mode,
            voice: start.voice,
            speed: start.speed,
            prep: start.prep,
            characters: body.count,
            words: ReadEvent.wordCount(of: body),
            appBundleId: start.appBundleId,
            appName: start.appName,
            outcome: .reading
        )
        activeId = event.id
        activeStartedAtMs = event.startedAtMs
        maxPosition = 0
        maxDuration = 0
        store.append(event)
        return event.id
    }

    /// First decoded chunk landed — records the latency users feel.
    /// Idempotent: only the first call for a read writes a value.
    public func noteFirstAudio() {
        guard let id = activeId else { return }
        store.update(id: id) { event in
            guard event.firstAudioMs == nil else { return }
            event.firstAudioMs = max(0, ReadEvent.currentTimeMs() - self.activeStartedAtMs)
        }
    }

    /// An article read learns its real title and word count only after
    /// extraction; a selection read learns nothing new. Safe to call at
    /// any point before the read finalizes.
    public func refine(title: String? = nil, detectedLang: String? = nil) {
        guard let id = activeId else { return }
        store.update(id: id) { event in
            if let title, !title.isEmpty { event.title = title }
            if let detectedLang { event.detectedLang = detectedLang }
        }
    }

    /// Synthesis or playback failed. Closes the record.
    public func noteFailure(_ message: String) {
        guard let id = activeId else { return }
        store.update(id: id) { $0.errorMessage = message }
        finalizeActive(outcome: .failed)
    }

    /// Close the open record, if any, choosing completed vs stopped from
    /// how much of the audio was heard. `forcedOutcome` overrides that.
    public func finalizeActive(outcome forcedOutcome: ReadOutcome? = nil) {
        guard let id = activeId else { return }
        let listened = maxPosition
        let audio = max(maxDuration, maxPosition)
        let outcome: ReadOutcome
        if let forcedOutcome, forcedOutcome == .failed {
            outcome = .failed
        } else if audio > 0, listened >= audio - Self.completionToleranceSeconds {
            outcome = .completed
        } else {
            outcome = forcedOutcome ?? .stopped
        }
        store.update(id: id) { event in
            event.listenedSeconds = listened
            event.audioSeconds = audio
            event.outcome = outcome
            event.endedAtMs = ReadEvent.currentTimeMs()
        }
        activeId = nil
        maxPosition = 0
        maxDuration = 0
    }

    /// Persist anything pending. Called from applicationWillTerminate.
    public func flush() {
        finalizeActive()
        store.flush()
    }

    // MARK: - player observation

    private func observePlayer() {
        // Sample while audio is moving. AudioPlayer publishes `position`
        // on a display-linked timer while playing, so this is the only
        // place the real listened-seconds number exists.
        player.$position
            .sink { [weak self] position in
                guard let self, self.activeId != nil else { return }
                if position > self.maxPosition { self.maxPosition = position }
            }
            .store(in: &cancellables)

        player.$duration
            .sink { [weak self] duration in
                guard let self, self.activeId != nil else { return }
                if duration > self.maxDuration { self.maxDuration = duration }
            }
            .store(in: &cancellables)

        // Idle means the clip drained or the user stopped it. Either way
        // this read is over; finalizeActive decides which.
        player.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                guard state == .idle, let id = self.activeId else { return }
                // Hop a turn so any final position sample published in the
                // same runloop pass is folded in before we finalize.
                //
                // The id check on the far side is load-bearing: AppDispatcher
                // calls player.stop() and THEN begins the next read, so this
                // sink fires for the *outgoing* read while the *incoming* one
                // is already open by the time the hop lands. Without the
                // check, every read would be finalized at zero seconds
                // listened the instant it started.
                Task { @MainActor [weak self] in
                    guard let self, self.activeId == id else { return }
                    self.finalizeActive()
                }
            }
            .store(in: &cancellables)
    }
}
