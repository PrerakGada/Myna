// MenuBarController.swift — owns the menu bar bird icon's state machine,
// the /v2/status polling loop, the Claude Code toast stack, and the
// "recent items" history. Mirrors v1's behaviour while extending for
// v0.2 S06 (menu redesign) and S07 (5-state icon).
//
// Polling cadence (S07 AC #3):
//   • 250ms while iconState != .idle
//   • 1.0s while iconState == .idle
//
// Icon transitions are debounced 150ms (S06 AC #1) to avoid flicker on
// rapid state changes.
//
// Exposes Combine publishers (via @Published) for the SwiftUI menu
// view to bind to: icon state, daemon status, registry items, player state,
// CC toast badge count.
import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class MenuBarController: ObservableObject, CCToastActions {

    // MARK: - polling cadences

    /// Polling interval while the icon state is non-idle (per S07 AC #3).
    public static let activePollingInterval: TimeInterval = 0.25
    /// Polling interval while idle.
    public static let idlePollingInterval: TimeInterval = 1.0
    /// Icon transition debounce (S06 AC #1, S07 AC #1).
    public static let iconDebounceInterval: TimeInterval = 0.15

    public enum DaemonReachability: String, Sendable, Equatable {
        case unknown
        case up
        case down
    }

    @Published public private(set) var reachability: DaemonReachability = .unknown
    @Published public private(set) var status: DaemonStatus?
    @Published public private(set) var registry: [RegistryItem] = []
    /// v2 registry pending list — populated by the new Track B endpoint.
    /// Falls back to empty when the endpoint isn't yet deployed.
    @Published public private(set) var ccPending: [RegistryV2Item] = []
    /// Debounced icon state. Updates 150ms after the underlying signals
    /// change. Bound to the menu-bar BirdIconView.
    @Published public private(set) var iconState: IconState = .idle
    /// Last raw signals computed from status + player. Exposed for tests.
    public private(set) var lastRawIconState: IconState = .idle

    /// Recent items the user has heard, newest first (≤5).
    @Published public private(set) var recents: [RecentItem] = []

    public let client: DaemonClient
    public let player: AudioPlayer
    public let updates: UpdateController
    public weak var settings: SettingsViewModel?
    public let toasts: CCToastController = CCToastController()
    private let recentsStore: RecentItemsStore

    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var playerCancellable: AnyCancellable?
    private var loadingCancellable: AnyCancellable?
    private var hadThinkingState: Bool = false

    public init(
        client: DaemonClient,
        player: AudioPlayer,
        updates: UpdateController,
        settings: SettingsViewModel? = nil,
        recentsStore: RecentItemsStore = .shared
    ) {
        self.client = client
        self.player = player
        self.updates = updates
        self.settings = settings
        self.recentsStore = recentsStore
        self.toasts.actions = self
        self.recents = recentsStore.load()

        // Re-evaluate the icon state whenever the player state flips —
        // catches the pause→idle and idle→playing transitions before the
        // next poll tick lands.
        playerCancellable = player.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.recomputeIconState() }
            }
        // Same for the pre-audio loading flag: when AppDispatcher flips
        // it true at hotkey time, we want the bird icon and the popover
        // hero to react inside one frame, not 200-300ms later after the
        // next daemon poll. We also call objectWillChange so the popover
        // (which reads `popoverModel()` on each body call) re-renders
        // its hero with a LoadingHero immediately.
        loadingCancellable = player.$isLoading
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.recomputeIconState()
                    self.objectWillChange.send()
                }
            }
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = await MainActor.run {
                    self?.iconState == .idle
                        ? Self.idlePollingInterval
                        : Self.activePollingInterval
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// One-shot refresh. Used by start() on each tick, and is safe to
    /// call manually from menu actions ("refresh now").
    public func refresh() async {
        do {
            let status = try await client.status()
            self.status = status
            self.reachability = .up
            self.registry = status.registry.items
        } catch {
            self.reachability = .down
            self.registry = []
        }
        // Pull the v2 registry list separately — it's a different endpoint
        // (Lane B) and may 404 pre-merge. registryListV2 swallows 404 → [].
        do {
            let list = try await client.registryListV2()
            self.ccPending = list.pending
        } catch {
            self.ccPending = []
        }
        let chime = settings?.toastChimeEnabled ?? true
        if settings?.ccToastsEnabled ?? true {
            toasts.ingest(registry: ccPending, chimeEnabled: chime)
        } else {
            toasts.dismissAll()
        }
        recomputeIconState()
    }

    /// Compute the canonical icon state from the current signals and
    /// debounce-publish to `iconState`.
    public func recomputeIconState() {
        let raw = IconStateMapping.compute(
            reachability: reachability,
            daemonStateRaw: status?.state.rawValue,
            isPlayerPaused: player.state == .paused,
            isPlayerPlaying: player.state == .playing,
            isEngineUp: status?.isEngineUp,
            isPlayerLoading: player.isLoading
        )
        lastRawIconState = raw
        if raw == iconState { return }

        // Fire thinking earcon at thinking-onset, gated by setting and
        // "never overlaps speech" rule (S07 AC #4).
        if raw == .thinking, !hadThinkingState, player.state != .playing {
            if settings?.thinkingEarconEnabled ?? false {
                Earcon.shared.play(.thinkingOnset)
            }
        }
        hadThinkingState = (raw == .thinking)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.iconDebounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.iconState = raw
            }
        }
    }

    // MARK: - popover state

    /// Build the popover model from current state. Called by MenuBarView
    /// on each render.
    public func popoverModel() -> PopoverModel {
        let nowReading: PopoverModel.NowReading?
        if player.state != .idle, let status = status {
            nowReading = PopoverModel.NowReading(
                title: lastReadTitle ?? "(untitled)",
                voice: status.config.voice,
                speed: player.speed,
                positionSeconds: player.position,
                durationSeconds: player.duration
            )
        } else {
            nowReading = nil
        }
        return PopoverModelBuilder.build(
            playerState: player.state,
            nowReading: nowReading,
            recents: recents,
            ccItems: ccPending,
            reachability: reachability,
            hotkeyLabelFor: HotkeyLabel.display(for:),
            isPlayerLoading: player.isLoading,
            loadingTitle: lastReadTitle
        )
    }

    /// Most-recent title the dispatcher recorded as "now reading".
    /// AppDispatcher pushes new entries via `recordNowReading(title:voice:)`.
    public private(set) var lastReadTitle: String?

    /// Record that Myna started reading something. Inserts into the
    /// recents ring (S06 Recent submenu) and updates `lastReadTitle`
    /// for the Now Reading header.
    public func recordNowReading(title: String, voice: String) {
        lastReadTitle = title
        let item = RecentItem(
            title: title,
            voice: voice,
            createdAtMs: RecentItem.currentTimeMs()
        )
        recentsStore.add(item)
        recents = recentsStore.load()
    }

    // MARK: - menu actions

    public func togglePause() {
        switch player.state {
        case .playing: player.pause()
        case .paused: player.resume()
        case .idle: break
        }
    }

    public func stopPlayback() {
        player.stop()
    }

    public func setSpeed(_ value: Double) {
        player.setSpeed(value)
    }

    public func seek(delta: TimeInterval) {
        player.seek(delta: delta)
    }

    public func playRegistry(item: RegistryItem, mode: PlayMode) {
        Task { [weak self] in
            do {
                _ = try await self?.client.playItem(id: item.id, mode: mode)
            } catch {
                // Surface in log only — menu UI will refresh on next tick.
            }
            await self?.refresh()
        }
    }

    /// Replay an item from the Recent submenu. v0.2 emits a notification
    /// that AppDispatcher catches to re-synthesise; if no dispatcher is
    /// listening this is a no-op.
    public func replayRecent(_ item: RecentItem) {
        NotificationCenter.default.post(
            name: .mynaReplayRecent,
            object: nil,
            userInfo: ["title": item.title, "voice": item.voice]
        )
    }

    public func openSettings() {
        // Fallback path used only on macOS 13. macOS 14+ uses SettingsLink in
        // MenuBarView, which is the only reliable way to open Settings from
        // an LSUIElement (accessory) app.
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    public func openLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([LogFileMirror.shared.currentLogURL])
    }

    /// Restart the daemon by re-loading its LaunchAgent. Hard-coded path
    /// matches the plist Lane B installs via Homebrew formula. Surfaced
    /// in the menu per S06 footer spec.
    public func restartDaemon() {
        let plistPath = NSString("~/Library/LaunchAgents/dev.myna.daemon.plist").expandingTildeInPath
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["kickstart", "-k", "gui/\(getuid())/dev.myna.daemon"]
        _ = try? task.run()
        // Backup: try a simple unload+load if kickstart doesn't take.
        // (Quietly fails when the plist isn't installed.)
        if !FileManager.default.fileExists(atPath: plistPath) {
            return
        }
    }

    // MARK: - CCToastActions

    public nonisolated func play(item: RegistryV2Item) {
        Task { [weak self] in
            do {
                _ = try await self?.client.registryPlayV2(id: item.id)
            } catch {
                // Logged elsewhere; menu/poll refresh will re-sync.
            }
            await self?.refresh()
        }
    }

    public nonisolated func discard(item: RegistryV2Item) {
        // Local-only: the toast controller already moved the id into
        // its `discardedIds` set, so no further server call needed.
        // (When Lane B adds a /v2/registry/dismiss endpoint we can wire
        // that here.)
    }
}

extension Notification.Name {
    /// Posted when a Recent submenu row is clicked. AppDispatcher
    /// observes and re-synthesises the same text in the same voice.
    public static let mynaReplayRecent = Notification.Name("dev.myna.app.replayRecent")
}
