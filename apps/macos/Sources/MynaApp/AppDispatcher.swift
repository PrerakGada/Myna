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
    /// The in-flight speak operation (capture → synthesize → enqueue).
    /// Tracked so a superseding speak or an explicit stop can cancel it.
    /// This matters most in one-shot mode, where synthesizeAndPlay spends
    /// several seconds buffering before any audio plays: without
    /// cancellation, the old buffering would finish and shove a stale
    /// clip into the fresh session that player.stop() just cleared.
    private var speakTask: Task<Void, Never>?
    /// Monotonic id bumped at the start of each synthesizeAndPlay. Lets
    /// that method's `defer` tell whether *this* invocation still owns the
    /// "Processing…" indicator: a superseding speak bumps it, so an older
    /// (cancelled) invocation won't clear the new session's spinner — and,
    /// because it's bumped only once synthesis actually begins, a speak
    /// that aborts before synthesis (e.g. no text selected) can't strand
    /// the flag ON either.
    private var speakGeneration = 0
    /// Block-based observer for .mynaReplayRecent (Recent-submenu tap or the
    /// pill's transcript-row tap). App-lifetime; never removed — matches
    /// AudioPlayer / PillController, which also keep observers for process life.
    private var replayObserver: NSObjectProtocol?

    // MARK: - seamless-playback tuning
    //
    // Measured on this engine: ~0.5s to first chunk, synthesis ~12× realtime,
    // total gen ≈ 4.6s per 1000 chars. So the limiter for gap-free playback
    // is the FIRST inter-chunk boundary: the tiny priority-first chunk can
    // drain before a large second chunk is ready. Asking for ~500-char "rest"
    // chunks means each one synthesizes in ~2-3s but plays for ~25-30s, so the
    // producer can't fall behind; a ~6s audio lead absorbs the startup
    // variance. Net: seamless, first audio in ~2-3s, any length.

    /// `chunk_chars` requested in seamless mode (small enough that each chunk
    /// is produced faster than it plays).
    private static let seamlessChunkChars = 500
    /// Seconds of decoded audio to buffer before starting playback. Above the
    /// largest single chunk's synth time, so the player never underruns.
    private static let leadBufferSeconds = 6.0

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

        // Re-speak a Recent item when its row is tapped (menu submenu or the
        // pill's transcript list). MenuBarController.replayRecent posts this;
        // we own the in-process player, so the replay flows through the same
        // synth+play pipeline as a hotkey — transport, pill, recents all apply.
        replayObserver = NotificationCenter.default.addObserver(
            forName: .mynaReplayRecent, object: nil, queue: .main
        ) { [weak self] note in
            guard let title = note.userInfo?["title"] as? String, !title.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.speakTask?.cancel()
                self.speakTask = Task { await self.synthesizeAndPlay(text: title, url: nil, mode: .full) }
            }
        }
    }

    public func attach(menuController: MenuBarController) {
        self.menuController = menuController
    }

    // MARK: - URLSchemeDispatching

    public func speakSelection(mode: SynthesizeMode) {
        speakTask?.cancel()
        speakTask = Task {
            guard let text = await selection.captureSelectedText() else {
                log.warn("speak-selection: no text captured")
                return
            }
            await synthesizeAndPlay(text: text, url: nil, mode: mode)
        }
    }

    public func readChrome() {
        speakTask?.cancel()
        speakTask = Task {
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
        // Cancel any in-flight buffering first so a one-shot clip that's
        // still synthesizing doesn't start playing right after we stop.
        speakTask?.cancel()
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
        speakGeneration &+= 1
        let myGeneration = speakGeneration
        player.isLoading = true
        // Belt-and-braces: if synthesis throws before any chunk arrives,
        // drop the flag so the UI doesn't get stuck showing "Processing…".
        // But only if no newer speak has superseded us: a superseding speak
        // bumps speakGeneration and now owns the indicator, so clearing here
        // would wrongly retract its spinner. Keying off the generation (not
        // Task.isCancelled) also avoids stranding the flag ON when a
        // superseding speak aborts before synthesis. Normal success already
        // cleared it in beginSession(), so this is a no-op there.
        defer { if speakGeneration == myGeneration { player.isLoading = false } }
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
            // Seamless mode asks the daemon for smaller "rest" chunks so each
            // one synthesizes faster than it plays (synthesis runs ~12×
            // realtime). That keeps the producer ahead of the player after a
            // short lead-buffer, so playback never stalls mid-clip — the whole
            // point of the rewrite below. Streaming mode keeps the daemon
            // default (larger chunks, fewer parts).
            chunkChars: settings.oneShotPlayback ? Self.seamlessChunkChars : nil,
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
            if settings.oneShotPlayback {
                // Seamless (lead-buffered streaming): collect a short head
                // start of audio, start playing it, then keep appending the
                // remaining chunks gap-free. Because synthesis runs ~12×
                // realtime and we asked for small chunks, the producer stays
                // far ahead of the player once it starts — so there is no
                // mid-clip stall AND first audio lands in ~2-3s, instead of
                // waiting for the WHOLE clip to synthesize (the old buffer-
                // everything one-shot made a 2000-char reply wait ~9s, a
                // 4000-char one ~19s). enqueueAll schedules the lead
                // contiguously; subsequent enqueue() calls append onto the
                // live session, which the player schedules back-to-back.
                let startTime = DispatchTime.now()
                var lead: [AVAudioPCMBuffer] = []
                var leadSeconds = 0.0
                var started = false
                var chunkCount = 0
                func elapsed() -> Double {
                    Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9
                }
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        guard let buffer = await decodeWAV(chunk.wavData) else {
                            log.error("failed to decode WAV chunk \(chunk.index)")
                            continue
                        }
                        if Task.isCancelled { break }
                        chunkCount += 1
                        if started {
                            // Lead already playing — append; the player
                            // schedules this onto the live node gap-free.
                            player.enqueue(buffer: buffer)
                        } else {
                            lead.append(buffer)
                            leadSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
                            if leadSeconds >= Self.leadBufferSeconds {
                                player.enqueueAll(lead)
                                lead.removeAll()
                                started = true
                                log.info(
                                    "seamless: first audio after \(String(format: "%.2f", elapsed()))s "
                                    + "(lead \(String(format: "%.1f", leadSeconds))s, \(chunkCount) chunks)")
                            }
                        }
                    }
                } catch {
                    // Partial mid-stream failure: play what we collected
                    // rather than dropping the whole clip. The scheduled
                    // buffers' completions still drain the player to idle.
                    // DIAGNOSTIC (v0.4.3): started/chunkCount/generation context
                    // so a field repro can correlate a truncated stream with a
                    // subsequent read finding the player non-idle.
                    log.error("synthesize failed (seamless, partial; started=\(started), "
                        + "chunks=\(chunkCount), gen=\(myGeneration)/\(speakGeneration)): \(error)")
                }
                // A superseding speak or an explicit stop cancelled us mid-
                // stream — don't shove a stale clip into the fresh session.
                guard !Task.isCancelled else { return }
                // Stream ended before the lead filled (a short reply) — play
                // whatever we gathered.
                if !started, !lead.isEmpty {
                    player.enqueueAll(lead)
                }
                log.info(
                    "seamless: synthesis complete in \(String(format: "%.2f", elapsed()))s "
                    + "(\(chunkCount) chunks)")
            } else {
                // Streaming: play each chunk the instant it decodes (fast
                // first-audio, but can stall between chunks on slow synth).
                for try await chunk in stream {
                    if let buffer = await decodeWAV(chunk.wavData) {
                        player.enqueue(buffer: buffer)
                    } else {
                        log.error("failed to decode WAV chunk \(chunk.index)")
                    }
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
