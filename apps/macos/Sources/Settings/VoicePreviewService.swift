// VoicePreviewService.swift — orchestrates voice previews in the
// Settings Voice tab (S09). Responsibilities:
//
//   • Fetch WAV from /v2/voices/preview/{voice_id} via DaemonClient
//   • Play it through an isolated AVAudioPlayer at -6dB
//   • Duck the existing main playback (AudioPlayer) to 30% during preview
//   • Cancel + restart cleanly when the user clicks a different voice
//   • Debounce 300ms / queue depth 1 on spam clicks
//   • Surface "Engine warming…" inline label for 2s on 503
//
// Implementation note: the preview plays through its own AVAudioPlayer
// (not AudioPlayer) so it doesn't interfere with the main playback
// queue. Ducking is done by reading/writing AudioPlayer's mixer gain.
//
// Tests use a mock AudioSink that records the gain envelope; no real
// audio session is created.
import AVFoundation
import Combine
import Foundation

@MainActor
public final class VoicePreviewService: ObservableObject {
    public enum State: Sendable, Equatable {
        case idle
        case loading(voiceId: String)
        case playing(voiceId: String)
        case warming(voiceId: String)
        case failed(voiceId: String, reason: String)
    }

    @Published public private(set) var state: State = .idle
    /// True iff a preview is in-flight (loading OR playing).
    public var isBusy: Bool {
        switch state {
        case .loading, .playing: return true
        case .idle, .warming, .failed: return false
        }
    }

    private let client: DaemonClient
    private weak var sink: AudioDuckable?
    private var currentTask: Task<Void, Never>?
    private var currentPlayer: AVAudioPlayer?
    private var lastClickAt: Date = .distantPast
    /// Per-call ducking restore handle. nil when not currently ducking.
    private var pendingRestore: (() -> Void)?

    /// Minimum gap between successive triggers (S09 AC: 300ms debounce).
    public static let debounceInterval: TimeInterval = 0.3
    /// Duck factor for the main playback during preview (S09 AC: 30%).
    public static let duckFactor: Float = 0.3
    /// Preview attenuation (S09 AC: -6dB).
    public static let previewGainLinear: Float = 0.501  // 10^(-6/20)
    /// Time the warming label stays visible after a 503 (S09 AC: 2s).
    public static let warmingMessageDuration: TimeInterval = 2.0

    public init(client: DaemonClient, sink: AudioDuckable?) {
        self.client = client
        self.sink = sink
    }

    /// Preview the given voice. Cancels any in-flight preview within
    /// ~100ms per S09 AC #4. Spam-click debounce (300ms) drops calls
    /// closer together than the threshold.
    public func preview(voiceId: String) {
        let now = Date()
        if now.timeIntervalSince(lastClickAt) < Self.debounceInterval {
            return
        }
        lastClickAt = now

        // Cancel anything in flight first.
        cancel()
        state = .loading(voiceId: voiceId)
        currentTask = Task { [weak self] in
            await self?.runPreview(voiceId: voiceId)
        }
    }

    /// Stop any in-flight preview and restore main playback volume.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        currentPlayer?.stop()
        currentPlayer = nil
        if let restore = pendingRestore {
            restore()
            pendingRestore = nil
        }
        if case .warming = state { return }  // let warming label timeout run
        state = .idle
    }

    // MARK: - private

    private func runPreview(voiceId: String) async {
        let data: Data
        do {
            data = try await client.voicePreview(voiceId: voiceId)
        } catch DaemonError.engineDown {
            await flashWarming(voiceId: voiceId)
            return
        } catch {
            state = .failed(voiceId: voiceId, reason: String(describing: error))
            return
        }
        if Task.isCancelled { return }
        await play(data: data, voiceId: voiceId)
    }

    private func play(data: Data, voiceId: String) async {
        // Duck the main playback to 30% while preview plays.
        if let sink = sink {
            let restore = sink.duck(to: Self.duckFactor)
            pendingRestore = restore
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-preview-\(voiceId)-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: tmp)
        }
        do {
            try data.write(to: tmp)
            let player = try AVAudioPlayer(contentsOf: tmp)
            player.volume = Self.previewGainLinear
            currentPlayer = player
            state = .playing(voiceId: voiceId)
            player.play()
            // Wait for natural end. Cancellation lets us skip the wait
            // (cancel() already stopped the player).
            while player.isPlaying && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            state = .failed(voiceId: voiceId, reason: String(describing: error))
        }
        // Restore main playback gain.
        if let restore = pendingRestore {
            restore()
            pendingRestore = nil
        }
        currentPlayer = nil
        if !Task.isCancelled {
            state = .idle
        }
    }

    private func flashWarming(voiceId: String) async {
        state = .warming(voiceId: voiceId)
        try? await Task.sleep(nanoseconds: UInt64(Self.warmingMessageDuration * 1_000_000_000))
        if case .warming(let id) = state, id == voiceId {
            state = .idle
        }
    }
}

/// Anything that can be ducked. AudioPlayer conforms (returns a closure
/// the service calls to restore the original gain). Tests pass a mock.
@MainActor
public protocol AudioDuckable: AnyObject {
    /// Duck the audio sink to `factor` (0..<1 of full volume). Returns a
    /// closure the caller must invoke when the preview is done to restore
    /// the prior gain.
    func duck(to factor: Float) -> () -> Void
}
