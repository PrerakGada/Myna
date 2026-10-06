// AutoReadController.swift — Claude Code hands-free, wired into the app.
//
// Watches the Claude Code registry (MenuBarController.ccPending) for items
// that arrive while the user is away, turns them into AutoReadJobs, and runs
// AutoReadEngine against the real player, the away signals and the
// microphone. It never plays audio itself: every passage goes through an
// AutoReadSink. The app uses ReadQueueSink: passages join the shared read
// queue behind anything the user is reading, and play through the same
// dispatcher as every other read, so auto-read gets the pill, transport
// controls and History, and there is one audio path.
//
// At the desk nothing changes: an arriving reply is left to the pill/card.
import AppKit
import Combine
import Foundation

/// Where auto-read hands its speech. The one seam between this feature and
/// the app's playback; a shared read queue can stand behind it later.
@MainActor
public protocol AutoReadSink: AnyObject {
    /// Speak one passage now, as a Claude Code read.
    func speak(_ text: String)
    /// Stop the passage this feature started. Never called for a user's read.
    func stopOwnRead()
}

/// Auto-read through the shared read queue. A passage waits behind whatever
/// the user is reading or has queued, where a Play click would cut in, and
/// stopping it touches only this feature's passage. `dispatcher.stop()`
/// would also empty the user's queue.
@MainActor
public final class ReadQueueSink: AutoReadSink {
    private let queue: ReadQueue
    private var ownId: QueuedRead.ID?

    public init(queue: ReadQueue = .shared) {
        self.queue = queue
    }

    public func speak(_ text: String) {
        let read = QueuedRead(text: text, source: .claudeCode)
        ownId = read.id
        _ = queue.enqueue(read)
    }

    public func stopOwnRead() {
        guard let id = ownId else { return }
        ownId = nil
        if queue.current?.id == id {
            queue.skip()
        } else {
            queue.remove(id: id)
        }
    }
}

/// The pre-queue sink: the in-process play path every Claude Code Play uses.
@MainActor
public final class ReplayNotificationSink: AutoReadSink {
    private let stopAction: @MainActor () -> Void

    public init(stop: @escaping @MainActor () -> Void) {
        self.stopAction = stop
    }

    public func speak(_ text: String) {
        NotificationCenter.default.post(
            name: .mynaReplayRecent, object: nil,
            userInfo: ["title": text, "source": ReadSource.claudeCode.rawValue])
    }

    public func stopOwnRead() {
        stopAction()
    }
}

@MainActor
public final class AutoReadController {
    /// An item counts as "arriving" only if it was announced this recently
    /// when Myna first sees it, so a daemon coming back after an outage
    /// never reads out a stale backlog. Generous on purpose: with the screen
    /// locked macOS may stretch the registry poll, and a reply that arrived
    /// while the user was away must still count.
    static let freshnessSeconds: TimeInterval = 300
    private static let tickInterval: UInt64 = 500_000_000

    private var engine = AutoReadEngine()
    private let player: AudioPlayer
    private let client: DaemonClient
    private let sink: AutoReadSink
    private weak var settings: SettingsViewModel?
    private let defaults: UserDefaults
    private let log = Log(.app)

    private var seenIds: Set<String> = []
    private var seeded = false
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?

    public init(
        player: AudioPlayer,
        client: DaemonClient,
        sink: AutoReadSink,
        settings: SettingsViewModel?,
        defaults: UserDefaults = .standard
    ) {
        self.player = player
        self.client = client
        self.sink = sink
        self.settings = settings
        self.defaults = defaults
    }

    public func start(observing menu: MenuBarController) {
        guard cancellables.isEmpty else { return }
        // All three publishers are set on the main actor (MenuBarController
        // and AudioPlayer are @MainActor), so these sinks run synchronously
        // on main — the same pattern HistoryRecorder relies on. Synchronous
        // matters for the loading edge: AppDispatcher stops the old read and
        // raises the flag for the new one in a single turn.
        // dropFirst: skip the empty value @Published replays on subscribe, so
        // the first real poll is what seeds "already there when Myna started".
        menu.$ccPending
            .dropFirst()
            .sink { [weak self] items in self?.ingest(items) }
            .store(in: &cancellables)
        player.$isLoading
            .removeDuplicates()
            .sink { [weak self] loading in
                guard loading, let self else { return }
                self.perform(self.engine.readStarted())
            }
            .store(in: &cancellables)
        player.$position
            .sink { [weak self] position in
                guard let self, self.engine.hasWork else { return }
                self.engine.progress(position: position, duration: self.player.duration)
            }
            .store(in: &cancellables)
    }

    // MARK: - arrivals

    private func ingest(_ items: [RegistryV2Item]) {
        engine.retain(pendingIds: Set(items.map(\.id)))
        guard seeded else {
            // Whatever is pending when Myna starts was not "just now".
            seenIds = Set(items.map(\.id))
            seeded = true
            return
        }
        let fresh = items.filter { !seenIds.contains($0.id) }
        guard !fresh.isEmpty else { return }
        seenIds.formUnion(fresh.map(\.id))
        let config = HandsFreeSettings.load(from: defaults)
        guard config.autoReadWhenAway || config.speakAlerts else { return }
        let now = Date()
        for item in fresh {
            guard let job = Self.job(
                for: item, config: config, boldClaimsOnly: settings?.ccBoldClaimsOnly ?? false,
                now: now, isAway: { self.isAway(hostBundleId: $0, config: config) })
            else { continue }
            if engine.enqueue(job, now: now) {
                log.info("hands-free: queued \(item.id) (\(item.isAttention ? "alert" : "reply"), \(item.projectId))")
            }
        }
        ensureTicking()
    }

    /// Decide whether an arriving item should be spoken, and how. Pure
    /// apart from the injected away check, so it's unit-tested directly.
    static func job(
        for item: RegistryV2Item,
        config: HandsFreeSettings,
        boldClaimsOnly: Bool,
        now: Date,
        isAway: (String?) -> Bool
    ) -> AutoReadJob? {
        let age = now.timeIntervalSince1970 - Double(item.announcedAtMs) / 1000
        guard age < freshnessSeconds, item.partlyHeard != true else { return nil }
        let sessionKey = item.sessionId ?? item.projectId
        if item.isAttention {
            guard config.speakAlerts, let line = HandsFreePhrasing.alertLine(for: item) else { return nil }
            let requiresAway = !config.alertsAtDesk
            guard !requiresAway || isAway(item.hostBundleId) else { return nil }
            return AutoReadJob(
                itemId: item.id, kind: .alert(idle: item.notificationType == "idle_prompt"),
                sessionKey: sessionKey, hostBundleId: item.hostBundleId,
                requiresAway: requiresAway, passages: [line])
        }
        guard config.autoReadWhenAway, isAway(item.hostBundleId) else { return nil }
        let passages = ReplySegmenter.passages(of: item.spokenText(boldClaimsOnly: boldClaimsOnly))
        guard !passages.isEmpty else { return nil }
        return AutoReadJob(
            itemId: item.id, kind: .reply, sessionKey: sessionKey,
            hostBundleId: item.hostBundleId, requiresAway: true,
            prefix: HandsFreePhrasing.replyPrefix(projectId: item.projectId),
            passages: passages)
    }

    // MARK: - ticking

    private func ensureTicking() {
        guard tickTask == nil, engine.hasWork else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.step() == true else { break }
                try? await Task.sleep(nanoseconds: Self.tickInterval)
            }
            self?.tickTask = nil
        }
    }

    /// One tick. Returns whether there is still work to tick for.
    private func step() -> Bool {
        let config = HandsFreeSettings.load(from: defaults)
        let busy = player.state != .idle || player.isLoading
        let conditions = AutoReadEngine.Conditions(
            playerBusy: busy,
            callActive: config.holdDuringCalls && MicrophoneUse.otherAppIsRecording(),
            now: Date())
        let signals = AwayProbe.current()
        perform(engine.tick(conditions) { job in
            AwayDecision.isAway(signals: signals, policy: config.away, hostBundleId: job.hostBundleId)
        })
        return engine.hasWork
    }

    private func isAway(hostBundleId: String?, config: HandsFreeSettings) -> Bool {
        AwayDecision.isAway(signals: AwayProbe.current(), policy: config.away, hostBundleId: hostBundleId)
    }

    // MARK: - effects

    private func perform(_ effects: [AutoReadEngine.Effect]) {
        for effect in effects {
            switch effect {
            case .speak(let text):
                sink.speak(text)
            case .stopOwnRead:
                log.info("hands-free: microphone in use — pausing the read")
                sink.stopOwnRead()
            case .heardInFull(let id):
                Task { [client] in _ = try? await client.registryDismissV2(id: id) }
            case .partlyHeard(let id, let rest):
                log.info("hands-free: \(id) partly heard; the rest stays as a card")
                Task { [client] in _ = try? await client.registryPartlyHeardV2(id: id, text: rest) }
            }
        }
    }
}
