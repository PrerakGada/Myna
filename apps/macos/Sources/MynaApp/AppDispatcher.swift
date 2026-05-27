// AppDispatcher.swift — the concrete URLSchemeDispatching impl that
// hotkeys and the URL scheme both route into. Owns the
// high-level operations:
//   - speak the selection (full or summary)
//   - extract + speak the front Chrome tab
//   - pause / resume / stop
//   - seek delta
//   - set / bump speed
//
// All audio actually plays through the in-process AudioPlayer; only
// synthesis is fanned out to the daemon over HTTP.
import AppKit
import AVFoundation
import Foundation

@MainActor
public final class AppDispatcher: URLSchemeDispatching, GestureActionTarget {
    private let client: DaemonClient
    private let player: AudioPlayer
    private let selection: SelectionService
    private let chrome: ChromeService
    private let settings: SettingsViewModel
    /// MenuBar controller for recording recent-items + "now reading"
    /// state (S06). Optional so URL-scheme tests can construct the
    /// dispatcher without a full menu bar.
    private weak var menuController: MenuBarController?
    private let log = Log(.app)

    public init(
        client: DaemonClient,
        player: AudioPlayer,
        selection: SelectionService,
        chrome: ChromeService,
        settings: SettingsViewModel,
        menuController: MenuBarController? = nil
    ) {
        self.client = client
        self.player = player
        self.selection = selection
        self.chrome = chrome
        self.settings = settings
        self.menuController = menuController
    }

    public func attach(menuController: MenuBarController) {
        self.menuController = menuController
    }

    // MARK: - URLSchemeDispatching

    public func speakSelection(mode: SynthesizeMode) {
        Task {
            guard let text = await selection.captureSelectedText() else {
                log.warn("speak-selection: no text captured")
                return
            }
            await synthesizeAndPlay(text: text, url: nil, mode: mode)
        }
    }

    public func readChrome() {
        Task {
            guard let url = chrome.frontTabURL() else {
                log.warn("read-chrome: no Chrome tab URL")
                return
            }
            await synthesizeAndPlay(text: nil, url: url, mode: .full)
        }
    }

    public func togglePause() {
        switch player.state {
        case .playing: player.pause()
        case .paused: player.resume()
        case .idle: break
        }
    }

    public func stop() {
        player.stop()
    }

    public func seek(delta: TimeInterval) {
        player.seek(delta: delta)
    }

    public func setSpeed(_ value: Double) {
        player.setSpeed(value)
    }

    public func bumpSpeed(_ delta: Double) {
        player.setSpeed(player.speed + delta)
    }

    // MARK: - private

    private func synthesizeAndPlay(text: String?, url: String?, mode: SynthesizeMode) async {
        player.stop()
        // Flip the pre-audio loading flag *immediately* so every
        // observer (menu-bar bird, popover hero, floating pill) gets
        // a "Processing…" affordance within a frame of the hotkey,
        // not 200-300ms later when the first chunk lands. AudioPlayer
        // auto-clears the flag inside beginSession() the moment real
        // audio starts, and also on stop().
        player.isLoading = true
        // Belt-and-braces: if synthesis throws before any chunk arrives,
        // we still need to drop the flag so the UI doesn't get stuck
        // showing "Processing…".
        defer { player.isLoading = false }
        // Capture frontmost app bundle id at request time so the daemon
        // can apply the voice wardrobe. nil if there's no foreground
        // app (rare — usually Finder or our own process).
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let req = SynthesizeRequest(
            text: text,
            url: url,
            voice: settings.voice,
            speed: settings.defaultSpeed,
            mode: mode,
            sessionId: UUID().uuidString,
            bundleId: bundleId
        )
        // Record into recents (S06 Recent submenu). Title is the URL
        // host or the first ~60 chars of the text if no URL.
        let recentTitle = computeRecentTitle(text: text, url: url)
        menuController?.recordNowReading(title: recentTitle, voice: settings.voice)
        // Surface the same preview into the FloatingPill bridge so the
        // expanded pill shows what's playing. Pill falls back to
        // "Speaking…" when this is nil. See PillBridge.swift for why
        // this is a separate sink from AudioPlayer.
        PillBridge.shared.publish(currentText: recentTitle, voice: settings.voice)
        do {
            let stream = client.synthesize(req) { metadata in
                // Hop to main actor — onMetadata fires on whichever
                // actor the stream consumer is on, which here is
                // already @MainActor (the for-await below).
                Task { @MainActor in
                    LangMismatchToastCenter.shared.surface(metadata)
                }
            }
            for try await chunk in stream {
                if let buffer = await decodeWAV(chunk.wavData) {
                    player.enqueue(buffer: buffer)
                } else {
                    log.error("failed to decode WAV chunk \(chunk.index)")
                }
            }
        } catch {
            log.error("synthesize failed: \(error)")
        }
    }

    /// Best-effort short title for the recents row. Per Sally's spec:
    /// titles truncate at 38 chars + ellipsis (RecentItem handles that;
    /// here we just supply the raw string).
    private func computeRecentTitle(text: String?, url: String?) -> String {
        if let url = url, let parsed = URL(string: url) {
            return parsed.host ?? url
        }
        if let text = text {
            return String(text.prefix(60))
        }
        return "(untitled)"
    }

    /// Decode a WAV blob into an AVAudioPCMBuffer by writing to a
    /// temporary file and re-reading. AVAudioFile doesn't accept
    /// raw Data, so a roundtrip through disk is the path of least
    /// resistance. The temp file is removed best-effort after the
    /// buffer is loaded.
    private func decodeWAV(_ data: Data) async -> AVAudioPCMBuffer? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-incoming-\(UUID().uuidString).wav")
        do {
            try data.write(to: tmp)
            let file = try AVAudioFile(forReading: tmp)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                return nil
            }
            try file.read(into: buffer)
            try? FileManager.default.removeItem(at: tmp)
            return buffer
        } catch {
            log.error("decodeWAV: \(error)")
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }
}
