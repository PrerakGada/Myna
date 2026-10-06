// AutoReadQueue.swift — the Claude Code auto-read queue, as a pure state machine.
//
// AutoReadController feeds this events (a job arrived, a read started, the
// player's position, a periodic tick with the player/call/away state) and
// carries out the effects it returns (speak a passage, stop our own read,
// tell the registry a reply was heard in full or only partly). No AppKit,
// no clock, no audio: every rule below is unit-tested by driving events.
//
// The rules:
//   • One thing speaks at a time. Jobs wait while any read is loading,
//     playing or paused — including one the user started themselves.
//   • Replies are read in arrival order, each introduced by its project.
//     A "needs you" alert goes ahead of replies that haven't started, but
//     never splits one that has.
//   • A reply is read a passage (about a paragraph) at a time. If the user
//     comes back, the current passage finishes and the rest is handed back
//     to the registry as a "Partly heard" card. Passages are what make that
//     stop land between sentences; the player itself can't stop "after this
//     sentence".
//   • If the user starts their own read, or presses stop, the auto-read gives
//     way at once and hands back what's left.
//   • While another app uses the microphone nothing starts, and a passage
//     already playing is stopped and said again from its start afterwards.
//   • An idle alert ("waiting for you") is dropped when that session's reply
//     is queued or was read aloud in the last five minutes: you just heard it.
import Foundation

public struct AutoReadJob: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case reply
        /// A "needs you" line. `idle` marks Claude Code's idle prompt.
        case alert(idle: Bool)
    }

    public let itemId: String
    public let kind: Kind
    /// Session identity for the alert rules: the session id, else the project.
    public let sessionKey: String
    public let hostBundleId: String?
    /// Speak only while the user is away. Always true for replies; false for
    /// alerts when the user asked to hear them at the desk too.
    public let requiresAway: Bool
    /// Said once, before the first passage ("From myna.").
    public let prefix: String?
    public let passages: [String]
    /// Index of the next passage to speak.
    public internal(set) var next: Int = 0

    public init(
        itemId: String,
        kind: Kind,
        sessionKey: String,
        hostBundleId: String? = nil,
        requiresAway: Bool = true,
        prefix: String? = nil,
        passages: [String]
    ) {
        self.itemId = itemId
        self.kind = kind
        self.sessionKey = sessionKey
        self.hostBundleId = hostBundleId
        self.requiresAway = requiresAway
        self.prefix = prefix
        self.passages = passages
    }

    public var isReply: Bool { kind == .reply }

    /// What to say for passage `index`; the first carries the prefix. A
    /// space, not a blank line: History titles a read by its first line.
    func spoken(_ index: Int) -> String {
        guard index == 0, let prefix, !prefix.isEmpty else { return passages[index] }
        return prefix + " " + passages[index]
    }

    /// The passages from `index` on, as one text for a "Partly heard" card.
    func rest(from index: Int) -> String {
        passages[min(index, passages.count)...].joined(separator: "\n\n")
    }
}

public struct AutoReadEngine {
    public enum Effect: Equatable, Sendable {
        /// Speak this through the app's one play path.
        case speak(String)
        /// Stop the passage the auto-read started (only ever our own).
        case stopOwnRead
        /// A reply was read to the end: take it off the pending list.
        case heardInFull(itemId: String)
        /// A reply was cut short after some of it was heard: re-announce the rest.
        case partlyHeard(itemId: String, rest: String)
    }

    /// What the controller sees on each tick.
    public struct Conditions: Equatable, Sendable {
        /// Any read is loading, playing or paused.
        public var playerBusy: Bool
        /// Another app is using the microphone (and the hold is on).
        public var callActive: Bool
        public var now: Date

        public init(playerBusy: Bool, callActive: Bool, now: Date) {
            self.playerBusy = playerBusy
            self.callActive = callActive
            self.now = now
        }
    }

    /// The player can drop to idle for a moment mid-read while it waits for
    /// a late chunk, so a passage only counts as over after this long idle.
    public static let settleSeconds: TimeInterval = 1.5
    /// A passage whose read never started (the play path ignored it) is
    /// abandoned after this long.
    public static let startTimeout: TimeInterval = 45
    /// "Heard to the end" allows the player's own drain to land a touch
    /// short — the same tolerance HistoryRecorder uses.
    public static let completionTolerance: Double = 1.5
    /// How long after a session's reply was read its idle alert stays quiet.
    public static let idleAlertQuietPeriod: TimeInterval = 300

    enum Phase: Equatable {
        /// Handed to the sink; its read hasn't started yet.
        case requested(at: Date)
        /// Its read started; this is what the player is doing.
        case playing
    }

    struct Active: Equatable {
        var job: AutoReadJob
        var passage: Int
        var phase: Phase
        /// The user came back during this passage: stop after it.
        var returned = false
        var maxPosition: Double = 0
        var maxDuration: Double = 0
        var idleSince: Date?

        var heardToEnd: Bool {
            maxDuration > 0 && maxPosition >= maxDuration - AutoReadEngine.completionTolerance
        }
        var heardSome: Bool { passage > 0 || maxPosition > 0.5 }
    }

    public private(set) var queue: [AutoReadJob] = []
    private(set) var active: Active?
    private var lastReplyReadAt: [String: Date] = [:]

    public init() {}

    public var hasWork: Bool { active != nil || !queue.isEmpty }
    /// The item whose passage is being read (or about to be).
    public var activeItemId: String? { active?.job.itemId }

    // MARK: - events

    /// Queue a job. Returns false when it's refused (a duplicate, an empty
    /// job, or an idle alert for a session that was just read).
    @discardableResult
    public mutating func enqueue(_ job: AutoReadJob, now: Date) -> Bool {
        guard !job.passages.isEmpty,
              active?.job.itemId != job.itemId,
              !queue.contains(where: { $0.itemId == job.itemId })
        else { return false }
        guard case .alert(let idle) = job.kind else {
            queue.append(job)
            return true
        }
        if idle {
            let replyWaiting = queue.contains { $0.isReply && $0.sessionKey == job.sessionKey }
                || (active.map { $0.job.isReply && $0.job.sessionKey == job.sessionKey } ?? false)
            if replyWaiting { return false }
            if let last = lastReplyReadAt[job.sessionKey],
               now.timeIntervalSince(last) < Self.idleAlertQuietPeriod {
                return false
            }
        }
        // One alert per session: a newer one replaces a queued older one.
        queue.removeAll { !$0.isReply && $0.sessionKey == job.sessionKey }
        // Ahead of replies that haven't started; behind one that has.
        let slot = queue.firstIndex { $0.isReply && $0.next == 0 } ?? queue.count
        queue.insert(job, at: slot)
        return true
    }

    /// Drop queued jobs whose item left the registry's pending list (played
    /// from a card, dismissed, superseded or expired).
    public mutating func retain(pendingIds: Set<String>) {
        queue.removeAll { !pendingIds.contains($0.itemId) }
    }

    /// A read began (the player's loading flag rose).
    public mutating func readStarted() -> [Effect] {
        guard var current = active else { return [] }
        switch current.phase {
        case .requested:
            current.phase = .playing
            current.idleSince = nil
            active = current
            return []
        case .playing:
            // A second read began while ours held the player: the user
            // started one. Give way and hand back what's left.
            active = nil
            let finished = current.idleSince != nil && current.heardToEnd
            let from = finished ? current.passage + 1 : current.passage
            return settle(current.job, restFrom: from, heardSome: finished || current.heardSome)
        }
    }

    /// The player's position and (growing) duration while our passage plays.
    public mutating func progress(position: Double, duration: Double) {
        guard var current = active, current.phase == .playing else { return }
        current.maxPosition = max(current.maxPosition, position)
        current.maxDuration = max(current.maxDuration, duration)
        active = current
    }

    /// Periodic step. `isAway` answers for a job's session (its host app
    /// matters for the "window isn't in front" signal).
    public mutating func tick(_ conditions: Conditions, isAway: (AutoReadJob) -> Bool) -> [Effect] {
        if let current = active {
            return tickActive(current, conditions, isAway: isAway)
        }
        return startNext(conditions, isAway: isAway)
    }

    // MARK: - private

    private mutating func tickActive(
        _ snapshot: Active, _ conditions: Conditions, isAway: (AutoReadJob) -> Bool
    ) -> [Effect] {
        var current = snapshot
        switch current.phase {
        case .requested(let at):
            guard conditions.now.timeIntervalSince(at) > Self.startTimeout else { return [] }
            active = nil
            return settle(current.job, restFrom: current.passage, heardSome: current.passage > 0)
        case .playing:
            if conditions.playerBusy {
                current.idleSince = nil
                if conditions.callActive {
                    // A call began mid-passage: stop, say this passage again after.
                    active = nil
                    var job = current.job
                    job.next = current.passage
                    queue.insert(job, at: 0)
                    return [.stopOwnRead]
                }
                if current.job.requiresAway, !current.returned, !isAway(current.job) {
                    current.returned = true
                }
                active = current
                return []
            }
            let idleSince = current.idleSince ?? conditions.now
            current.idleSince = idleSince
            guard conditions.now.timeIntervalSince(idleSince) >= Self.settleSeconds else {
                active = current
                return []
            }
            active = nil
            return finishPassage(current)
        }
    }

    private mutating func finishPassage(_ finished: Active) -> [Effect] {
        guard finished.heardToEnd else {
            // Stopped short: the user pressed stop, or synthesis failed.
            return settle(finished.job, restFrom: finished.passage, heardSome: finished.heardSome)
        }
        var job = finished.job
        job.next = finished.passage + 1
        if job.next >= job.passages.count {
            return settle(job, restFrom: job.next, heardSome: true)
        }
        if finished.returned {
            return settle(job, restFrom: job.next, heardSome: true)
        }
        queue.insert(job, at: 0)
        return []
    }

    private mutating func startNext(
        _ conditions: Conditions, isAway: (AutoReadJob) -> Bool
    ) -> [Effect] {
        var effects: [Effect] = []
        // The user is back: whatever waits for "away" stays a normal card.
        while let head = queue.first, head.requiresAway, !isAway(head) {
            queue.removeFirst()
            effects += settle(head, restFrom: head.next, heardSome: head.next > 0)
        }
        guard let job = queue.first, !conditions.playerBusy, !conditions.callActive else {
            return effects
        }
        queue.removeFirst()
        active = Active(job: job, passage: job.next, phase: .requested(at: conditions.now))
        if job.isReply, job.next == 0 {
            lastReplyReadAt[job.sessionKey] = conditions.now
        }
        effects.append(.speak(job.spoken(job.next)))
        return effects
    }

    /// The registry outcome for a job that stops here. Alerts have none:
    /// they stay on screen until their session moves on.
    private func settle(_ job: AutoReadJob, restFrom index: Int, heardSome: Bool) -> [Effect] {
        guard job.isReply else { return [] }
        if index >= job.passages.count { return [.heardInFull(itemId: job.itemId)] }
        if heardSome { return [.partlyHeard(itemId: job.itemId, rest: job.rest(from: index))] }
        return []
    }
}
