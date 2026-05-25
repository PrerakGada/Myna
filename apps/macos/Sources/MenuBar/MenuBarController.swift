// MenuBarController.swift — owns the MenuBarExtra's data + drives the
// /v2/status polling loop. Mirrors v1's 1.5-second cadence.
//
// Exposes Combine publishers (via @Published) for the SwiftUI menu
// view to bind to: daemon status, registry items, player state.
import Combine
import Foundation
import SwiftUI

@MainActor
public final class MenuBarController: ObservableObject {
    /// Polling interval. v1 used 1.5s; the daemon also serves /v2/status
    /// cheaply enough that more frequent polling would still be fine.
    public static let pollingInterval: TimeInterval = 1.5

    public enum DaemonReachability: String, Sendable, Equatable {
        case unknown
        case up
        case down
    }

    @Published public private(set) var reachability: DaemonReachability = .unknown
    @Published public private(set) var status: DaemonStatus?
    @Published public private(set) var registry: [RegistryItem] = []

    public let client: DaemonClient
    public let player: AudioPlayer
    public let updates: UpdateController

    private var pollTask: Task<Void, Never>?

    public init(client: DaemonClient, player: AudioPlayer, updates: UpdateController) {
        self.client = client
        self.player = player
        self.updates = updates
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.pollingInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
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

    public func openSettings() {
        // SwiftUI's standard Settings scene is shown via `showSettingsWindow:`
        // on AppKit; we route via NSApp.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    public func openLogs() {
        NSWorkspace.shared.activateFileViewerSelecting([LogFileMirror.shared.currentLogURL])
    }
}
