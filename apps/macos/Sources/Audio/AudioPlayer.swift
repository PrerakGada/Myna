// AudioPlayer.swift — @MainActor wrapper around AVAudioEngine that owns
// the entire playback graph:
//
//   AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixerNode → output
//
// Responsibilities:
//   - enqueue PCM buffers (one per WAV chunk)
//   - sample-accurate pause/resume
//   - speed change without pitch shift (TimePitchUnit)
//   - seek within and across chunks against a virtual timeline
//   - publish state, position, duration to subscribers (Combine + KVO)
//
// Concurrency: this class is @MainActor — every method runs on the main
// actor. The completion callbacks AVAudioEngine fires on its render
// thread hop back to main via Task { @MainActor in ... }.
//
// Tests use the real AVAudioEngine but feed in-memory sine wave
// buffers (no disk I/O). See AudioTests/AudioPlayerTests.swift.
import AVFoundation
import Combine
import Foundation
import QuartzCore

@MainActor
public final class AudioPlayer: ObservableObject {
    public enum State: String, Sendable, Equatable {
        case idle
        case playing
        case paused
    }

    // MARK: published state

    @Published public private(set) var state: State = .idle
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var speed: Double = 1.0

    // MARK: engine

    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let timePitch: TimePitchUnit
    private var queue: PlaybackQueue
    /// True iff the player node is connected to the time-pitch unit.
    /// Connections are made lazily once we have a real buffer format
    /// to anchor them to.
    private var graphConnected: Bool = false

    // MARK: playback bookkeeping

    /// Index into `queue.chunks` of the chunk currently being played.
    private var currentChunkIndex: Int = 0
    /// Offset (in seconds) into the current chunk where playback last
    /// started/resumed. Used to compute live position.
    private var currentChunkStartOffset: TimeInterval = 0
    /// Wall-clock anchor (CACurrentMediaTime) of when the current
    /// chunk segment started playing. Sample-accuracy would require
    /// AVAudioTime, but `playerNode.lastRenderTime` is nil until the
    /// engine has rendered at least one quantum — that race made the
    /// first 100-200ms of position reads always return 0. Wall clock
    /// is good enough for menu-bar position UI; sample-accuracy would
    /// matter only for AV sync, which we don't need.
    private var playStartWallTime: CFTimeInterval?
    /// Active session token. Bumped on stop() / new session, used to
    /// drop stale buffer-completion callbacks that fire after a stop.
    private var sessionToken: Int = 0
    /// Position when paused (so resume picks up exactly where we left off).
    private var pausedAtOffset: TimeInterval = 0
    /// Wall clock for position polling.
    private var positionTimer: Timer?
    /// Cache: format of the chunks we're currently playing.
    /// AVAudioEngine connections need a consistent format; we (re-)wire
    /// the graph if the format changes between sessions.
    private var connectedFormat: AVAudioFormat?

    // MARK: init

    public init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        self.timePitch = TimePitchUnit()
        self.queue = PlaybackQueue()
        engine.attach(playerNode)
        engine.attach(timePitch.underlyingUnit)
    }

    // Note: no deinit cleanup of `positionTimer` — the Timer is added
    // to the main run loop, and Swift 6's strict concurrency forbids
    // touching @MainActor-isolated state from a nonisolated deinit.
    // stop() is the documented teardown path; tests + AppDelegate call
    // it. Leaking a Timer on dealloc is harmless (it retains the player
    // via its closure, and the closure no-ops after `weak self` goes
    // nil — RunLoop GC eventually reclaims it).

    // MARK: queue management

    /// Append a PCM buffer to the end of the playback queue. Auto-starts
    /// playback if the queue was empty and the engine is idle.
    public func enqueue(buffer: AVAudioPCMBuffer) {
        let nextIndex = queue.chunks.count
        let chunk = QueuedChunk(index: nextIndex, buffer: buffer)
        queue.append(chunk)
        duration = queue.totalDuration

        // If the player is idle and this is the very first chunk, prime
        // the graph and start playing.
        if state == .idle && nextIndex == 0 {
            beginSession()
        } else if state == .playing || state == .paused {
            // Already a session in flight — schedule this new chunk so
            // the player auto-plays it when prior chunks finish.
            scheduleChunk(index: nextIndex, fromOffset: 0, completionToken: sessionToken)
        }
    }

    // MARK: transport

    public func play() {
        if queue.isEmpty {
            return
        }
        if state == .paused {
            resume()
            return
        }
        if state == .idle {
            beginSession()
        }
        // Already playing — no-op.
    }

    public func pause() {
        guard state == .playing else { return }
        // Snapshot position before stopping the node so position
        // continues to read correctly after pause.
        pausedAtOffset = liveChunkOffset()
        playerNode.pause()
        positionTimer?.invalidate()
        positionTimer = nil
        state = .paused
        updatePositionPublished()
    }

    public func resume() {
        guard state == .paused else { return }
        playerNode.play()
        // Re-anchor host time so position math stays correct after pause.
        playStartWallTime = CACurrentMediaTime()
        currentChunkStartOffset = pausedAtOffset
        state = .playing
        startPositionTimer()
    }

    public func stop() {
        sessionToken &+= 1
        playerNode.stop()
        positionTimer?.invalidate()
        positionTimer = nil
        queue.removeAll()
        duration = 0
        position = 0
        currentChunkIndex = 0
        currentChunkStartOffset = 0
        pausedAtOffset = 0
        playStartWallTime = nil
        state = .idle
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: speed

    public func setSpeed(_ newValue: Double) {
        let clamped = max(Double(TimePitchUnit.minRate), min(Double(TimePitchUnit.maxRate), newValue))
        speed = clamped
        timePitch.rate = Float(clamped)
        // Pitch stays at 0 — verified by tests.
    }

    // MARK: seek

    /// Seek to an absolute global position. Clamps to [0, totalDuration].
    public func seek(to globalPosition: TimeInterval) {
        let total = queue.totalDuration
        guard !queue.isEmpty, total > 0 else { return }
        let target = max(0, min(globalPosition, total))
        guard let location = queue.locate(globalPosition: target) else { return }

        let resumePlaying = (state == .playing)
        sessionToken &+= 1
        playerNode.stop()
        currentChunkIndex = location.chunkIndex
        currentChunkStartOffset = location.offsetInChunk
        pausedAtOffset = location.offsetInChunk
        position = target

        // If we landed exactly at the end (i.e. seek past total), stop
        // out as if natural completion.
        if target >= total {
            state = .idle
            positionTimer?.invalidate()
            positionTimer = nil
            return
        }

        scheduleChunk(index: location.chunkIndex, fromOffset: location.offsetInChunk, completionToken: sessionToken)
        for nextIdx in (location.chunkIndex + 1)..<queue.chunks.count {
            scheduleChunk(index: nextIdx, fromOffset: 0, completionToken: sessionToken)
        }

        if resumePlaying || state == .paused {
            do {
                try startEngineIfNeeded()
                playerNode.play()
                playStartWallTime = CACurrentMediaTime()
                state = .playing
                startPositionTimer()
            } catch {
                state = .idle
            }
        }
    }

    /// Seek by a delta in seconds. Positive forward, negative backward.
    public func seek(delta: TimeInterval) {
        seek(to: position + delta)
    }

    // MARK: session bring-up

    private func beginSession() {
        sessionToken &+= 1
        guard let firstChunk = queue.chunks.first else { return }
        connectGraphIfNeeded(for: firstChunk.buffer.format)
        currentChunkIndex = 0
        currentChunkStartOffset = 0
        pausedAtOffset = 0
        position = 0
        duration = queue.totalDuration
        for idx in queue.chunks.indices {
            scheduleChunk(index: idx, fromOffset: 0, completionToken: sessionToken)
        }
        do {
            try startEngineIfNeeded()
            playerNode.play()
            playStartWallTime = CACurrentMediaTime()
            state = .playing
            startPositionTimer()
        } catch {
            state = .idle
        }
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func connectGraphIfNeeded(for format: AVAudioFormat) {
        if graphConnected && connectedFormat == format { return }
        if graphConnected {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch.underlyingUnit)
        }
        engine.connect(playerNode, to: timePitch.underlyingUnit, format: format)
        engine.connect(timePitch.underlyingUnit, to: engine.mainMixerNode, format: format)
        graphConnected = true
        connectedFormat = format
    }

    // MARK: scheduling

    private func scheduleChunk(index: Int, fromOffset offset: TimeInterval, completionToken token: Int) {
        guard index >= 0 && index < queue.chunks.count else { return }
        let chunk = queue.chunks[index]
        let buffer = chunk.buffer
        let sampleRate = buffer.format.sampleRate
        let startFrame = AVAudioFramePosition(offset * sampleRate)
        let totalFrames = AVAudioFrameCount(buffer.frameLength)
        let framesToPlay = totalFrames > AVAudioFrameCount(startFrame) ? totalFrames - AVAudioFrameCount(startFrame) : 0
        if framesToPlay == 0 {
            scheduleCompletion(forChunk: index, token: token)
            return
        }
        // Fast path: offset == 0 means just play the whole buffer,
        // which scheduleBuffer can do with no disk I/O.
        if startFrame == 0 {
            playerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: [],
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleChunkCompletion(index: index, token: token)
                }
            }
            return
        }
        // Slow path (seek into the middle of a buffer): scheduleSegment
        // requires an AVAudioFile, so we materialise the buffer to a
        // temp .caf once and cache the file handle.
        let timeAnchor: AVAudioTime? = nil
        playerNode.scheduleSegment(
            mapBufferToFile(buffer),
            startingFrame: startFrame,
            frameCount: framesToPlay,
            at: timeAnchor,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleChunkCompletion(index: index, token: token)
            }
        }
    }

    /// scheduleSegment requires an AVAudioFile. We synthesize a one-shot
    /// in-memory file by writing the buffer to a temp file. To keep the
    /// fast path fast and avoid I/O for every chunk, callers should
    /// prefer enqueue(buffer:) which uses scheduleBuffer when offset == 0;
    /// this helper is the fallback for non-zero offset seeks.
    private func mapBufferToFile(_ buffer: AVAudioPCMBuffer) -> AVAudioFile {
        if let cached = bufferFileCache[ObjectIdentifier(buffer)] {
            return cached
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-chunk-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: buffer.format.settings)
            try file.write(from: buffer)
            // Re-open for reading; AVAudioFile opened for writing can't
            // be used with scheduleSegment.
            let readable = try AVAudioFile(forReading: tmp)
            bufferFileCache[ObjectIdentifier(buffer)] = readable
            return readable
        } catch {
            // Should be exceedingly rare; surface as a fatal so tests see it.
            fatalError("AudioPlayer: failed to materialize chunk for seeking: \(error)")
        }
    }

    private var bufferFileCache: [ObjectIdentifier: AVAudioFile] = [:]

    private func scheduleCompletion(forChunk index: Int, token: Int) {
        Task { @MainActor [weak self] in
            self?.handleChunkCompletion(index: index, token: token)
        }
    }

    private func handleChunkCompletion(index: Int, token: Int) {
        // Drop late callbacks from a previous session.
        guard token == sessionToken else { return }
        // Advance bookkeeping if this was the latest in-flight chunk.
        if index >= currentChunkIndex {
            currentChunkIndex = index + 1
            currentChunkStartOffset = 0
            playStartWallTime = CACurrentMediaTime()
        }
        // End of queue?
        if currentChunkIndex >= queue.chunks.count {
            // Snap position to total and go idle.
            position = queue.totalDuration
            state = .idle
            positionTimer?.invalidate()
            positionTimer = nil
        }
    }

    // MARK: position computation

    /// Seconds elapsed inside the current chunk since the most recent
    /// (chunk start / seek / resume). Accounts for playback rate.
    private func liveChunkOffset() -> TimeInterval {
        guard let anchor = playStartWallTime else {
            return currentChunkStartOffset
        }
        let elapsedSeconds = max(0, CACurrentMediaTime() - anchor)
        return currentChunkStartOffset + elapsedSeconds * Double(timePitch.rate)
    }

    private func updatePositionPublished() {
        guard !queue.isEmpty else {
            position = 0
            return
        }
        let offset = liveChunkOffset()
        let chunkOffsetCapped = min(offset, queue.chunks[safe: currentChunkIndex]?.duration ?? offset)
        let priorDurations = queue.chunks.prefix(currentChunkIndex).reduce(0) { $0 + $1.duration }
        position = min(queue.totalDuration, priorDurations + chunkOffsetCapped)
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePositionPublished()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }
}

// MARK: - safe subscript

extension Array {
    fileprivate subscript(safe idx: Int) -> Element? {
        indices.contains(idx) ? self[idx] : nil
    }
}
