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
//
// Every read goes through the ReadQueue (Sources/Queue/): the entry points
// below submit to it, and this class is its performer — it plays whatever
// the queue hands it and reports when that read's synthesis ends. Which
// entry points queue and which interrupt is ReadQueuePolicy's table.
import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation

@MainActor
public final class AppDispatcher: URLSchemeDispatching, GestureActionTarget, MenuBarActionTarget {
    private let client: DaemonClient
    private let player: AudioPlayer
    private let selection: SelectionService
    private let chrome: ChromeService
    private let settings: SettingsViewModel
    /// MenuBar controller for recording recent-items + "now reading"
    /// state (S06). Optional so URL-scheme tests can construct the
    /// dispatcher without a full menu bar.
    private weak var menuController: MenuBarController?
    /// Records every read into the durable history the Dashboard reads
    /// from. Optional so URL-scheme and dispatcher tests can construct
    /// a dispatcher without a store on disk.
    private let history: HistoryRecorder?
    private let log = Log(.app)
    /// The in-flight synthesis of the read the queue is playing (synthesize
    /// → enqueue into the player). Tracked so Skip, Stop or an interrupting
    /// read can cancel it. Selection capture runs outside it, on purpose.
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
    /// What plays next. A read that arrives while Myna is busy waits here
    /// instead of cutting the current one off.
    private let queue: ReadQueue
    /// The Reading pane's queue-or-interrupt choice, read on every press so
    /// a change applies at once.
    private let readKeyPreference: () -> ReadKeyWhileReading
    /// Token of the read whose synthesis task is still running. Nil once it
    /// ends or is halted; `isReading` uses it to cover the gap before audio.
    private var synthesisToken: Int?
    /// True while this dispatcher is stopping the player itself (starting a
    /// read, skipping, stopping), so the player's `.stopped` event isn't
    /// mistaken for the pill's Stop button and clear the queue.
    private var stoppingInternally = false
    private var sessionEndObserver: AnyCancellable?
    /// Writes a summary read's summary, on this Mac when it can (Sources/Summaries/).
    let summaries: SummaryService

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
        menuController: MenuBarController? = nil,
        history: HistoryRecorder? = nil,
        queue: ReadQueue = .shared,
        readKeyPreference: @escaping () -> ReadKeyWhileReading = { ReadKeyWhileReading.current() },
        summaries: SummaryService = .shared
    ) {
        self.client = client
        self.player = player
        self.selection = selection
        self.chrome = chrome
        self.settings = settings
        self.menuController = menuController
        self.history = history
        self.queue = queue
        self.readKeyPreference = readKeyPreference
        self.summaries = summaries
        summaries.attach(daemon: client)
        queue.performer = self
        // Synchronous, on the main actor: AudioPlayer sends from inside
        // stop() / its drain, after `state` is already idle.
        sessionEndObserver = player.sessionEnds.sink { [weak self] end in
            self?.playerSessionEnded(end)
        }

        // Re-speak a Recent item when its row is tapped (menu submenu or the
        // pill's transcript list). MenuBarController.replayRecent posts this;
        // we own the in-process player, so the replay flows through the same
        // synth+play pipeline as a hotkey — transport, pill, recents all apply.
        replayObserver = NotificationCenter.default.addObserver(
            forName: .mynaReplayRecent, object: nil, queue: .main
        ) { [weak self] note in
            // A Recent row carries the full text (or the article URL); the
            // pill's Claude prompt sends the reply as "title".
            let info = note.userInfo ?? [:]
            let url = (info["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let text = (info["text"] as? String) ?? (info["title"] as? String) ?? ""
            // Claude Code replies tag themselves so History files them under
            // Claude Code rather than as a replay.
            let source = (info["source"] as? String).flatMap(ReadSource.init(rawValue:)) ?? .replay
            guard url != nil || !text.isEmpty else { return }
            // An explicit Play click: it starts now, whatever is playing.
            Task { @MainActor [weak self] in
                self?.submit(text: url == nil ? text : nil, url: url, source: source, from: .playClick)
            }
        }
    }

    public func attach(menuController: MenuBarController) {
        self.menuController = menuController
    }

    // MARK: - URLSchemeDispatching

    public func speakSelection(mode: SynthesizeMode) {
        if mode == .summary { summaries.prewarm() }  // loads while the selection is captured
        // Capture runs outside the queue: the selection has to be read
        // now, while the user's app is still in front, even if the read
        // itself waits its turn.
        Task {
            guard let captured = await selection.capture(mode: settings.selectionCaptureMode) else {
                log.warn("speak-selection: no text captured")
                Self.presentNoSelectionNotice(on: menuController)
                return
            }
            submit(text: captured.text, mode: mode, source: .selection, from: .selectionKey)
        }
    }

    /// Speak text handed over by the Services menu ("Read with Myna" /
    /// "Summarize with Myna"). The requesting app already gave us the
    /// selection, so there is no capture step and no permission involved.
    /// Recorded as a `.selection` read: that is what the user did.
    public func speakServiceText(_ text: String, mode: SynthesizeMode) {
        // A Services request is the read key by another route, so it
        // queues or interrupts by the same setting.
        speakLiteral(text, mode: mode, source: .selection, from: .selectionKey)
    }

    /// Speak a literal string. Used by the popover's clipboard actions and
    /// anything else that already holds the text, so it skips the ⌘C capture
    /// dance entirely — which is what makes it safe to trigger from the
    /// popover, where Myna itself is the frontmost app.
    ///
    /// Routes through the same synth+play pipeline as a hotkey, so transport,
    /// the floating pill, recents and the now-reading title all behave
    /// identically to a selection read.
    public func speakText(_ text: String, mode: SynthesizeMode = .full) {
        speakLiteral(text, mode: mode, source: .clipboard, from: .clipboard)
    }

    private func speakLiteral(_ text: String, mode: SynthesizeMode, source: ReadSource, from entry: ReadEntryPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(text: trimmed, mode: mode, source: source, from: entry)
    }

    public func readChrome() {
        Task {
            guard let url = chrome.frontTabURL() else {
                log.warn("read-chrome: no Chrome tab URL")
                menuController?.showNotice(
                    title: "No article to read",
                    hint: "Myna reads the front tab in Google Chrome. Open an article there and try again."
                )
                return
            }
            submit(url: url, source: .article, from: .articleKey)
        }
    }

    /// Open the Dashboard window. Routed through the dispatcher because the
    /// URL scheme already talks to exactly this object; the launcher itself
    /// is a singleton, so there is nothing to inject.
    public func openDashboard(pane: DashboardPane?) {
        DashboardLauncher.shared.present(pane: pane)
    }

    public func togglePause() {
        switch player.state {
        case .playing: player.pause()
        case .paused: player.resume()
        case .idle: break
        }
    }

    /// Stop means everything: the current read and every queued one.
    public func stop() {
        queue.stop()
    }

    /// End the current read and start the next queued one (or just end it
    /// when nothing is waiting).
    public func skip() {
        queue.skip()
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

    /// Hand a read to the queue, which plays it now or lines it up
    /// depending on where it came from (ReadQueuePolicy) and whether Myna
    /// is already reading. The frontmost app is captured here, at request
    /// time, so a queued read keeps the voice of the app it came from.
    private func submit(
        text: String? = nil, url: String? = nil, mode: SynthesizeMode = .full,
        source: ReadSource, from entry: ReadEntryPoint
    ) {
        let front = NSWorkspace.shared.frontmostApplication
        let read = QueuedRead(
            text: text, url: url, mode: mode, source: source,
            appBundleId: front?.bundleIdentifier, appName: front?.localizedName)
        let placement = ReadQueuePolicy.placement(for: entry, preference: readKeyPreference())
        switch queue.submit(read, placement: placement) {
        case .playing, .duplicate:
            break
        case .queued:
            // A key press while reading used to cut in, which is loud
            // feedback. Waiting in line is silent, so say it took.
            menuController?.showNotice(
                title: "Added to the queue",
                hint: "It plays when the current read finishes. Stop clears the queue."
            )
        case .full:
            menuController?.showNotice(
                title: "The queue is full",
                hint: "Myna holds \(queue.capacity) reads. Skip or remove one, or press Stop to clear them."
            )
        }
    }

    /// Stop the player on the dispatcher's own account — starting a read,
    /// skipping, stopping — so `playerSessionEnded` doesn't treat it as the
    /// user pressing Stop on the pill.
    private func stopPlayerInternally() {
        stoppingInternally = true
        player.stop()
        stoppingInternally = false
    }

    private func playerSessionEnded(_ end: AudioPlayer.SessionEnd) {
        switch end {
        case .drained:
            queue.playbackDidDrain()
        case .stopped:
            // The pill, popover and Dashboard Stop buttons call player.stop()
            // directly; this is how the queue hears about them.
            if !stoppingInternally { queue.playbackWasStopped() }
        }
    }

    /// Synthesize one read and feed its audio to the player. Returns a
    /// description of the failure when synthesis threw, nil otherwise
    /// (including when it was cancelled — the caller checks that).
    @discardableResult
    private func synthesizeAndPlay(_ read: QueuedRead) async -> String? {
        let text = read.text, url = read.url, mode = read.mode
        stopPlayerInternally()
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
        // The bundle id was captured when the read was requested (see
        // `submit`), so the daemon applies the wardrobe voice of the app the
        // text came from even if the read waited in the queue.
        announceStart(read)
        let step = await request(for: read)  // a summary read's summary is written now, at its turn
        guard case .send(let req) = step else { return Self.present(step, on: menuController, history: history) }
        // A mid-stream failure in seamless mode still plays what arrived;
        // it's remembered here so the queue can log why the read was short.
        var partialFailure: String?
        do {
            let stream = client.synthesize(req) { metadata in
                // Hop to main actor — onMetadata fires on whichever
                // actor the stream consumer is on, which here is
                // already @MainActor (the for-await below).
                Task { @MainActor [weak self] in
                    LangMismatchToastCenter.shared.surface(metadata)
                    if let lang = metadata.detectedLang, metadata.langMismatch {
                        self?.history?.refine(detectedLang: lang)
                    }
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
                var leadChunks: [SynthesizedChunk] = []
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
                        history?.noteFirstAudio()
                        chunkCount += 1
                        if started {
                            // Lead already playing — append; the player
                            // schedules this onto the live node gap-free.
                            player.enqueue(buffer: buffer)
                            TranscriptStore.shared.didEnqueue(readID: read.id, chunk: chunk, buffer: buffer)
                        } else {
                            lead.append(buffer)
                            leadChunks.append(chunk)
                            leadSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
                            if leadSeconds >= Self.leadBufferSeconds {
                                player.enqueueAll(lead)
                                TranscriptStore.shared.didEnqueue(readID: read.id, chunks: leadChunks, buffers: lead)
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
                    partialFailure = String(describing: error)
                    Self.present(summaries.halt(after: error, mode: mode), on: menuController, history: history)
                }
                // A superseding speak or an explicit stop cancelled us mid-
                // stream — don't shove a stale clip into the fresh session.
                guard !Task.isCancelled else { return nil }
                // Stream ended before the lead filled (a short reply) — play
                // whatever we gathered.
                if !started, !lead.isEmpty {
                    player.enqueueAll(lead)
                    TranscriptStore.shared.didEnqueue(readID: read.id, chunks: leadChunks, buffers: lead)
                }
                log.info(
                    "seamless: synthesis complete in \(String(format: "%.2f", elapsed()))s "
                    + "(\(chunkCount) chunks)")
            } else {
                try await playAsItArrives(stream, readID: read.id, mode: mode)
            }
        } catch {
            log.error("synthesize failed: \(error)")
            history?.noteFailure(String(describing: error))
            return String(describing: error)
        }
        return partialFailure
    }

    /// Streaming playback, plus the notice when the daemon couldn't write a summary.
    private func playAsItArrives(
        _ stream: AsyncThrowingStream<SynthesizedChunk, Error>, readID: UUID, mode: SynthesizeMode
    ) async throws {
        do { try await playAsItArrives(stream, readID: readID) } catch {
            Self.present(summaries.halt(after: error, mode: mode), on: menuController, history: history)
            throw error
        }
    }

    /// Streaming: play each chunk the instant it decodes (fast first-audio,
    /// but can stall between chunks on slow synth).
    private func playAsItArrives(
        _ stream: AsyncThrowingStream<SynthesizedChunk, Error>, readID: UUID
    ) async throws {
        for try await chunk in stream {
            // Same guard as seamless mode: after Skip or Stop, a chunk that
            // was mid-decode must not land in the next read's session.
            if Task.isCancelled { break }
            if let buffer = await decodeWAV(chunk.wavData) {
                if Task.isCancelled { break }
                history?.noteFirstAudio()
                player.enqueue(buffer: buffer)
                TranscriptStore.shared.didEnqueue(readID: readID, chunk: chunk, buffer: buffer)
            } else {
                log.error("failed to decode WAV chunk \(chunk.index)")
            }
        }
    }

    /// Build the synthesize request for one read.
    ///
    /// Seamless mode asks the daemon for smaller "rest" chunks so each one
    /// synthesizes faster than it plays (synthesis runs ~12× realtime).
    /// That keeps the producer ahead of the player after a short lead
    /// buffer, so playback never stalls mid-clip. Streaming mode keeps the
    /// daemon default: larger chunks, fewer parts.
    /// `source`, and the prep the settings give it, pick how the daemon
    /// cleans the text up.
    func makeRequest(
        text: String?, url: String?, mode: SynthesizeMode, bundleId: String?, source: ReadSource
    ) -> SynthesizeRequest {
        SynthesizeRequest(
            text: text,
            url: url,
            voice: settings.voice,
            speed: settings.defaultSpeed,
            mode: mode,
            chunkChars: settings.oneShotPlayback ? Self.seamlessChunkChars : nil,
            sessionId: UUID().uuidString,
            bundleId: bundleId,
            source: source.rawValue,
            prep: settings.textPrep(for: source)
        )
    }

    /// Tell every "what is playing" sink that a read has begun: the
    /// recents ring, the floating pill, and the durable history the
    /// Dashboard reads from. One place, so the three can never disagree
    /// about what Myna is currently reading.
    private func announceStart(_ read: QueuedRead) {
        let text = read.text, url = read.url
        // Title is the URL host, or the first ~60 chars of the text.
        let title = computeRecentTitle(text: text, url: url)
        menuController?.recordNowReading(
            title: title, voice: settings.voice, text: text, url: url)
        // The pill falls back to "Speaking…" when this is nil. See
        // PillBridge.swift for why it's a separate sink from AudioPlayer.
        PillBridge.shared.publish(currentText: title, voice: settings.voice)
        // Opened at the same moment as recents, so a read appears in the
        // Dashboard while it is still playing; HistoryRecorder closes it
        // out when the player drains or the user stops.
        history?.begin(
            HistoryRecorder.Start(
                title: title,
                text: text,
                url: url,
                source: read.source,
                mode: read.mode.rawValue,
                voice: settings.voice,
                speed: settings.defaultSpeed,
                appBundleId: read.appBundleId,
                appName: read.appName,
                prep: settings.textPrep(for: read.source).rawValue
            )
        )
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

// MARK: - ReadPerformer

extension AppDispatcher: ReadPerformer {
    /// Play `read` now. Called only by the queue, which has already decided
    /// that this read's turn has come.
    public func perform(_ read: QueuedRead, token: Int) {
        speakTask?.cancel()
        synthesisToken = token
        speakTask = Task { [weak self] in
            // Halted before it began (Stop or Skip in the gap between two
            // reads): don't flash "Processing…" or open a history row for a
            // read nobody will hear.
            guard let self, !Task.isCancelled else { return }
            let failure = await self.synthesizeAndPlay(read)
            // Cancelled means a newer read, Skip or Stop took over, and
            // whoever did that has already moved the queue on.
            guard !Task.isCancelled else { return }
            TranscriptStore.shared.synthesisDidEnd(readID: read.id)
            if self.synthesisToken == token { self.synthesisToken = nil }
            self.queue.synthesisDidEnd(
                token: token, failure: failure, playerIdle: self.player.state == .idle)
        }
    }

    public func halt() {
        // Cancel any in-flight buffering first so a one-shot clip that's
        // still synthesizing doesn't start playing right after we stop.
        speakTask?.cancel()
        speakTask = nil
        synthesisToken = nil
        // Skipped when the player is already idle — which is always the case
        // when the queue halts because the pill's Stop already stopped it,
        // so stop() is never re-entered from inside its own event.
        if player.state != .idle || player.isLoading { stopPlayerInternally() }
    }

    public var isReading: Bool {
        synthesisToken != nil || player.state != .idle || player.isLoading
    }
}
