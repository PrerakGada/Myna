// ReadQueue.swift — what Myna reads next.
//
// Before the queue, every read cancelled the one playing: press the read key
// on a second paragraph and the first was cut off mid-sentence. Now a read
// that arrives while Myna is busy waits its turn and plays when the current
// one finishes (unless the user chose "Interrupts" in the Reading pane, or
// the read is an explicit Play click — see ReadQueuePolicy.swift).
//
// The queue owns the *sequence* and nothing else. It never touches audio or
// the daemon: a `ReadPerformer` (AppDispatcher in the app, a fake in tests)
// synthesizes and plays one read at a time and reports back. That seam is
// what lets anything enqueue — the hotkeys through the dispatcher today,
// Claude Code auto-read later — without knowing how a read is played.
//
// API (everything is @MainActor):
//
//   ReadQueue.shared                        the app's queue; views observe it
//   submit(_:placement:) -> SubmitResult    .queueIfBusy, or .playNow (replaces
//                                           the current read, keeps the waiting ones)
//   enqueue(_:) -> SubmitResult             submit(.queueIfBusy), for other producers
//   skip()                                  end the current read, start the next
//   stop()                                  end the current read and empty the queue
//   remove(id:) / clear()                   drop one / every waiting read
//   current, items, count, isBusy           state (current and items are @Published)
//
// Performer → queue (the "read finished" signal):
//
//   synthesisDidEnd(token:failure:playerIdle:)  every chunk of the read is in the
//                                               player, or synthesis failed
//   playbackDidDrain()                          the player ran out of audio
//   playbackWasStopped()                        someone stopped the player outside
//                                               the queue (the pill's Stop button)
//
// A read is over only when BOTH halves have happened: synthesis ended AND the
// player is idle. If the player is already idle when synthesis ends (nothing
// played, or a streaming read drained first) the read is over at once;
// otherwise the next drain ends it. A drain that arrives while synthesis is
// still running is a mid-read underrun in streaming mode and is ignored.
// Every performed read carries a token, so a late callback from a read that
// was skipped, stopped or interrupted can never move the queue a second time.
//
// Everything runs on the main actor, so there is no window in which a read is
// appended to a queue that has just gone idle: a submit either sees the
// current read (and waits behind it) or sees none (and plays at once).
//
// The queue is ephemeral by design. It lives in memory and is gone when Myna
// quits; a persisted "listen later" list is a different feature.
import Combine
import Foundation

/// One read, captured whole at the moment it was asked for.
///
/// The frontmost app is recorded here rather than when the read's turn
/// comes, so a queued read plays in the voice of the app it came from (the
/// daemon's per-app voice wardrobe keys on the bundle id), not in the voice
/// of whatever app happens to be in front minutes later.
public struct QueuedRead: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The text to speak. Nil for an article read, which sends `url`.
    public let text: String?
    /// Article URL for the daemon to extract. Nil for a text read.
    public let url: String?
    public let mode: SynthesizeMode
    public let source: ReadSource
    public let appBundleId: String?
    public let appName: String?
    public let submittedAt: Date

    public init(
        text: String? = nil,
        url: String? = nil,
        mode: SynthesizeMode = .full,
        source: ReadSource,
        appBundleId: String? = nil,
        appName: String? = nil,
        id: UUID = UUID(),
        submittedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.url = url
        self.mode = mode
        self.source = source
        self.appBundleId = appBundleId
        self.appName = appName
        self.submittedAt = submittedAt
    }

    /// Two reads are the same request when they would say the same thing the
    /// same way. Whitespace is collapsed because two ⌘C captures of one
    /// selection can differ in a trailing newline; the mode is part of the
    /// key because "read it" and "summarise it" are different requests.
    public var dedupeKey: String {
        let body = url ?? Self.collapsingWhitespace(text ?? "")
        return "\(mode.rawValue)|\(body)"
    }

    /// The first few words, for the queue list. An article shows its host.
    public var preview: String {
        if let url, let host = URL(string: url)?.host { return host }
        if let url { return url }
        let words = Self.collapsingWhitespace(text ?? "").split(separator: " ")
        let head = words.prefix(Self.previewWordCount).joined(separator: " ")
        let clipped = head.count > Self.previewCharacterLimit
            ? String(head.prefix(Self.previewCharacterLimit)).trimmingCharacters(in: .whitespaces)
            : head
        let truncated = words.count > Self.previewWordCount || clipped.count < head.count
        return truncated ? clipped + "\u{2026}" : clipped
    }

    static let previewWordCount = 8
    static let previewCharacterLimit = 48

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// Whoever actually speaks a read. The app's is AppDispatcher.
@MainActor
public protocol ReadPerformer: AnyObject {
    /// Start `read` now, replacing whatever is playing. Report the end of its
    /// synthesis through `ReadQueue.synthesisDidEnd(token:failure:playerIdle:)`
    /// with the same `token` — unless `perform` or `halt` is called again
    /// first, in which case report nothing.
    func perform(_ read: QueuedRead, token: Int)
    /// Cancel any synthesis in flight and stop the player. Reports nothing.
    func halt()
    /// True while a read is being synthesized or the player is playing,
    /// paused or loading. Used only to notice a lost end-of-read signal.
    var isReading: Bool { get }
}

@MainActor
public final class ReadQueue: ObservableObject {
    /// The app's queue. Views, the dispatcher and other producers share it.
    public static let shared = ReadQueue()

    /// Enough to line up a morning's reading; small enough that a stuck key
    /// can't bury the user under hours of audio.
    public static let defaultCapacity = 20

    public enum Placement: Sendable, Equatable {
        /// Play now if nothing is being read, otherwise wait in line.
        case queueIfBusy
        /// Replace the current read. Waiting reads keep their places.
        case playNow
    }

    public enum SubmitResult: Sendable, Equatable {
        /// Started at once.
        case playing
        /// Waiting; `position` is its 1-based place in line.
        case queued(position: Int)
        /// Same as the current read or one already waiting. Nothing changed.
        case duplicate
        /// The queue is at capacity. Nothing changed.
        case full
    }

    /// The read in progress: synthesizing, playing or paused. Nil when idle.
    @Published public private(set) var current: QueuedRead?
    /// Reads waiting their turn, next first. Excludes `current`.
    @Published public private(set) var items: [QueuedRead] = []

    public let capacity: Int
    /// Weak: the dispatcher owns the queue relationship, not the other way.
    public weak var performer: ReadPerformer?

    /// Number of waiting reads (not counting the one playing).
    public var count: Int { items.count }
    /// True while a read is in progress.
    public var isBusy: Bool { current != nil }
    /// "+2 queued" when reads are waiting, nil when none are. Every surface
    /// (pill, popover, Dashboard) uses this wording.
    public var countLabel: String? { Self.countLabel(for: count) }

    /// The same wording for a count taken from `$items`, which publishes
    /// before the property itself changes.
    public static func countLabel(for count: Int) -> String? {
        count > 0 ? "+\(count) queued" : nil
    }

    /// Identifies the read handed to the performer most recently. Bumped on
    /// every start, skip and stop, so callbacks for anything older are stale.
    public private(set) var token = 0
    /// Set once the current read's synthesis has ended with audio still
    /// playing: the next drain ends the read.
    private var awaitingDrain: Int?
    private let log = Log(.app)

    public init(capacity: Int = ReadQueue.defaultCapacity, performer: ReadPerformer? = nil) {
        self.capacity = max(1, capacity)
        self.performer = performer
    }

    // MARK: - producers

    @discardableResult
    public func submit(_ read: QueuedRead, placement: Placement) -> SubmitResult {
        recoverIfStuck()
        guard current != nil, placement == .queueIfBusy else {
            start(read)
            return .playing
        }
        let key = read.dedupeKey
        if current?.dedupeKey == key || items.contains(where: { $0.dedupeKey == key }) {
            log.info("queue: ignored a duplicate of a read already playing or waiting")
            return .duplicate
        }
        guard items.count < capacity else {
            log.warn("queue: full (\(capacity)); dropped a \(read.source.rawValue) read")
            return .full
        }
        items.append(read)
        log.info("queue: \(read.source.rawValue) read queued at \(items.count)")
        return .queued(position: items.count)
    }

    /// Wait in line behind the current read, or play at once when idle.
    @discardableResult
    public func enqueue(_ read: QueuedRead) -> SubmitResult {
        submit(read, placement: .queueIfBusy)
    }

    // MARK: - transport

    /// End the current read and start the next one. With nothing waiting it
    /// just ends the current read, so "skip this" always does something.
    public func skip() {
        guard current != nil else {
            if !items.isEmpty { startNextOrIdle() }
            return
        }
        log.info("queue: skip (\(items.count) waiting)")
        if items.isEmpty {
            stop()
        } else {
            startNextOrIdle()
        }
    }

    /// End the current read and drop every waiting one.
    public func stop() {
        if current != nil || !items.isEmpty {
            log.info("queue: stop (dropped \(items.count) waiting)")
        }
        items.removeAll()
        token &+= 1
        awaitingDrain = nil
        current = nil
        performer?.halt()
    }

    /// Drop one waiting read. The read in progress isn't in `items`, so it
    /// can't be removed this way — Skip or Stop ends it.
    public func remove(id: QueuedRead.ID) {
        items.removeAll { $0.id == id }
    }

    /// Drop every waiting read and let the current one finish.
    public func clear() {
        items.removeAll()
    }

    // MARK: - performer callbacks

    /// Synthesis for the read with `token` is over: every chunk is in the
    /// player, or it failed (`failure` says why). `playerIdle` is the
    /// player's state at that moment.
    public func synthesisDidEnd(token: Int, failure: String?, playerIdle: Bool) {
        guard token == self.token, current != nil else { return }
        if let failure {
            log.warn("queue: read failed, moving on to the next: \(failure)")
        }
        if playerIdle {
            startNextOrIdle()
        } else {
            awaitingDrain = token
        }
    }

    /// The player played the last audio it had.
    public func playbackDidDrain() {
        guard let awaiting = awaitingDrain, awaiting == token, current != nil else { return }
        startNextOrIdle()
    }

    /// The player was stopped by something other than the performer — the
    /// pill's, popover's or Dashboard's Stop button. Stop means everything.
    public func playbackWasStopped() {
        guard current != nil || !items.isEmpty else { return }
        stop()
    }

    // MARK: - internals

    private func start(_ read: QueuedRead) {
        token &+= 1
        awaitingDrain = nil
        current = read
        guard let performer else {
            log.error("queue: no performer attached; dropping a \(read.source.rawValue) read")
            current = nil
            return
        }
        performer.perform(read, token: token)
    }

    private func startNextOrIdle() {
        awaitingDrain = nil
        if items.isEmpty {
            token &+= 1
            current = nil
        } else {
            start(items.removeFirst())
        }
    }

    /// The queue believes a read is in progress, yet the performer has no
    /// synthesis in flight and the player is idle: an end-of-read signal was
    /// lost. Without this, every later read would wait behind one that can
    /// never finish. Treat the stuck read as over and carry on.
    private func recoverIfStuck() {
        guard current != nil, let performer, !performer.isReading else { return }
        log.warn("queue: current read had ended without a signal; moving on")
        startNextOrIdle()
    }
}
