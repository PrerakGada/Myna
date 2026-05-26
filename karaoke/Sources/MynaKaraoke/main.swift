// main.swift — AppDelegate bootstrap for the karaoke sidecar.
//
// Tier 1 lifecycle:
//   - sidecar is spawned by the daemon
//   - listens on ~/.myna/karaoke.sock (binary creates it on launch)
//   - daemon connects as client; sidecar reads NDJSON until EOF
//   - 10s of idle (no client) → clean exit
//   - parent died (getppid()==1) → clean exit
//
// All AppKit calls happen on the main thread; socket I/O on a bg queue.

import AppKit
import Foundation
import MynaKaraokeCore

/// AppDelegate is main-actor isolated for AppKit work. The
/// `SocketListenerDelegate` methods are `nonisolated` because the listener
/// invokes them on its background queue; they hop to main via DispatchQueue.
final class AppDelegate: NSObject, NSApplicationDelegate, SocketListenerDelegate, @unchecked Sendable {
    @MainActor let panel = PanelController()
    @MainActor var listener: SocketListener?
    @MainActor var idleTimer: Timer?
    @MainActor var parentWatchTimer: Timer?

    /// CLI override of the socket path. Defaults to ~/.myna/karaoke.sock.
    @MainActor var socketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.myna/karaoke.sock"
    }()

    @MainActor
    func applicationDidFinishLaunching(_ note: Notification) {
        parseCommandLine()
        startListener()
        startParentWatch()
    }

    @MainActor
    func applicationWillTerminate(_ note: Notification) {
        listener?.stop()
        idleTimer?.invalidate()
        parentWatchTimer?.invalidate()
    }

    // MARK: - CLI parsing

    @MainActor
    private func parseCommandLine() {
        // Supports: --socket /path/to/file
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--socket":
                if i + 1 < args.count {
                    socketPath = args[i + 1]
                    i += 2
                    continue
                }
            default:
                break
            }
            i += 1
        }
    }

    // MARK: - Listener

    @MainActor
    private func startListener() {
        let newListener = SocketListener(socketPath: socketPath)
        newListener.delegate = self
        do {
            try newListener.start()
            FileHandle.standardError.write(
                Data("karaoke: listening at \(socketPath)\n".utf8)
            )
        } catch {
            FileHandle.standardError.write(
                Data("karaoke: failed to bind \(socketPath): \(error)\n".utf8)
            )
            exit(1)
        }
        listener = newListener
        // No client yet — start the idle timer right away. If daemon connects
        // quickly we cancel it; if it doesn't, we exit cleanly.
        startIdleTimer()
    }

    // SocketListenerDelegate — called on the listener's background queue.
    // Marked nonisolated; bodies hop to main.

    nonisolated func didConnect() {
        DispatchQueue.main.async { [weak self] in
            self?.cancelIdleTimer()
        }
    }

    nonisolated func didReceive(_ message: IncomingMessage) {
        DispatchQueue.main.async { [weak self] in
            self?.panel.handle(message)
        }
    }

    nonisolated func didDisconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.startIdleTimer()
        }
    }

    // MARK: - Idle exit (10s after disconnect)

    @MainActor
    private func startIdleTimer() {
        cancelIdleTimer()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            FileHandle.standardError.write(
                Data("karaoke: 10s idle — exiting\n".utf8)
            )
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @MainActor
    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Parent-gone watch (5s poll on getppid())

    @MainActor
    private func startParentWatch() {
        parentWatchTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            if getppid() == 1 {
                FileHandle.standardError.write(
                    Data("karaoke: parent gone — exiting\n".utf8)
                )
                Task { @MainActor in NSApp.terminate(nil) }
            }
        }
    }
}

// Bootstrap.
@MainActor
func bootstrap() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // LSUIElement=YES in Info.plist would normally hide from the Dock; we also
    // set the activation policy explicitly so this works when launched without
    // a bundle (e.g. from `swift run` during development).
    app.setActivationPolicy(.accessory)
    // Hold a strong ref so ARC doesn't drop AppDelegate.
    objc_setAssociatedObject(app, "myna.karaoke.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}

MainActor.assumeIsolated { bootstrap() }
