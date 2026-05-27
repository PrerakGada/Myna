// OnboardingController.swift — coordinates the first-run cinematic
// (S11). Owns the SwiftUI view model, feeds each slide's spoken text
// to the daemon, waits for playback to finish, and advances.
//
// Concurrency: @MainActor — drives a SwiftUI view. The daemon stream
// is awaited from the main actor (it's nonisolated under the hood).
import AVFoundation
import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI

/// Lifecycle stages of the onboarding flow. The view binds to `phase`
/// to swap content. `completed` and `skipped` terminate the window.
public enum OnboardingPhase: Equatable {
    case showing(slideIndex: Int)
    case completed
    case skipped
}

@MainActor
public final class OnboardingController: ObservableObject {
    /// Current phase. SwiftUI view re-renders on change.
    @Published public private(set) var phase: OnboardingPhase = .showing(slideIndex: 0)
    /// Set to `true` while we're awaiting synthesis from the daemon.
    /// View shows a subtle dot animation in this state (CSS-style, no
    /// TimelineView — we just toggle a Bool inside `.animation`).
    @Published public private(set) var isSpeaking = false
    /// Captions row: the spoken line, shown live under the body so
    /// VoiceOver users / muted users follow along (S11 AC #7).
    @Published public private(set) var caption: String = ""

    public let slides: [OnboardingSlide]
    private let client: DaemonClient?
    private let player: AudioPlayer?
    private let voice: String?
    private let speed: Double
    private let store: WhatsNewStateStore
    private let log = Log(.app)

    /// Per-slide synthesis task. Cancelled on skip / advance so we
    /// don't pile up daemon streams.
    private var currentSynthTask: Task<Void, Never>?
    /// Fallback timer fires if synthesis hangs or fails — keeps the
    /// cinematic moving (S11 AC #5).
    private var fallbackTask: Task<Void, Never>?
    /// Combine subscription to `player.$state`. We advance when the
    /// player transitions from `.playing` → `.idle` (audio drained).
    private var playerObservation: AnyCancellable?
    /// Suppresses spurious advance during the brief window between
    /// `player.stop()` and the next slide's first chunk arriving —
    /// otherwise the .idle that immediately follows .playing → .stop
    /// would prematurely advance the next slide.
    private var awaitingFirstChunk = false
    /// Bumped on each slide start so stale observation callbacks from
    /// the previous slide's player don't advance.
    private var observationToken = 0

    /// Default init wires the controller to live daemon + player. Pass
    /// `nil` for either to run a *silent* cinematic (used in SwiftUI
    /// previews and unit tests). When silent, the controller drives the
    /// flow purely on `fallbackDuration` timers.
    public init(
        client: DaemonClient?,
        player: AudioPlayer?,
        voice: String? = nil,
        speed: Double = 1.0,
        slides: [OnboardingSlide] = OnboardingScript.all,
        store: WhatsNewStateStore = .shared
    ) {
        self.client = client
        self.player = player
        self.voice = voice
        self.speed = speed
        self.slides = slides
        self.store = store
    }

    public var currentSlide: OnboardingSlide? {
        guard case .showing(let i) = phase, slides.indices.contains(i) else { return nil }
        return slides[i]
    }

    /// Kick off the cinematic. Speaks slide 0, advances on completion.
    public func start() {
        guard !slides.isEmpty else {
            finish(skipped: false)
            return
        }
        speakCurrentSlide()
    }

    /// Manual "Next" — bypass the audio-driven advance. Used by the
    /// inline forward affordance on each slide.
    public func advance() {
        guard case .showing(let i) = phase else { return }
        if i + 1 >= slides.count {
            finish(skipped: false)
            return
        }
        // Cancel in-flight audio so the next slide gets a clean stream.
        cancelInFlightWork()
        player?.stop()
        phase = .showing(slideIndex: i + 1)
        speakCurrentSlide()
    }

    /// Skip everything. Per S11 AC #3: skip writes first_run_complete
    /// + first_run_scene_reached so a future v0.3 cinematic could
    /// resume. We just persist the current index for forward-compat.
    public func skip() {
        cancelInFlightWork()
        player?.stop()
        finish(skipped: true)
    }

    /// Final "Get Started" — requests Accessibility (if not already
    /// asked elsewhere) and marks first-run complete.
    public func getStarted() {
        cancelInFlightWork()
        player?.stop()
        requestAccessibilityPermission()
        finish(skipped: false)
    }

    // MARK: - private

    private func finish(skipped: Bool) {
        var state = store.load()
        state.firstRunComplete = true
        state.lastUpdatedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        // Seed last_seen_version with the currently-installed marketing
        // version so the What's New dialog doesn't immediately re-fire
        // for this user (parallels WhatsNewLauncher.markFirstRunComplete).
        if state.lastSeenVersion == "0.0.0",
            let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        {
            state.lastSeenVersion = raw
        }
        _ = store.save(state)
        phase = skipped ? .skipped : .completed
    }

    private func cancelInFlightWork() {
        currentSynthTask?.cancel()
        currentSynthTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        playerObservation?.cancel()
        playerObservation = nil
        isSpeaking = false
    }

    /// Speak the current slide's spoken text, advance when the player
    /// transitions back to idle (or when the fallback timer fires).
    private func speakCurrentSlide() {
        guard let slide = currentSlide else { return }
        caption = slide.spoken

        cancelInFlightWork()
        observationToken &+= 1
        let token = observationToken
        awaitingFirstChunk = true

        // Always arm the fallback timer — it's a hard cap on how long
        // we'll wait for audio. S11 AC #5: 30s max per scene. We use
        // the slide's `fallbackDuration` (typically much shorter) since
        // it represents the *intended* tempo, not the hang ceiling.
        startFallbackTimer(duration: slide.fallbackDuration, token: token)

        // No daemon / player wired up → silent mode (SwiftUI previews,
        // VoiceOver path, daemon down). The fallback timer drives advance.
        guard let client, let player else {
            return
        }

        // Observe the player so we advance the slide when its audio
        // drains. We subscribe BEFORE kicking off synthesis so we
        // don't miss the playing → idle transition for short clips.
        observePlayerForCompletion(token: token)

        isSpeaking = true
        currentSynthTask = Task { [weak self] in
            await self?.streamSpokenText(slide.spoken, voice: self?.voice, client: client, player: player, token: token)
        }
    }

    private func streamSpokenText(
        _ text: String,
        voice: String?,
        client: DaemonClient,
        player: AudioPlayer,
        token: Int
    ) async {
        let req = SynthesizeRequest(
            text: text,
            url: nil,
            voice: voice,
            speed: speed,
            mode: .full,
            sessionId: UUID().uuidString
        )
        do {
            for try await chunk in client.synthesize(req) {
                if Task.isCancelled || token != observationToken { return }
                if let buffer = await decodeWAV(chunk.wavData) {
                    player.enqueue(buffer: buffer)
                    // First chunk arrived → release the "ignore early
                    // idle" suppression so the eventual drain advances.
                    awaitingFirstChunk = false
                }
            }
        } catch {
            log.error("onboarding: synthesize failed: \(error)")
            // Synthesis failed mid-flight. The fallback timer will
            // advance us; nothing else to do here.
            isSpeaking = false
        }
        // Synthesis complete. Audio drain is observed separately via
        // playerObservation.
    }

    /// Subscribe to `player.$state`. When we see `.playing` → `.idle`
    /// (the queue drained naturally), advance the slide. Stale tokens
    /// from previous slides are filtered.
    private func observePlayerForCompletion(token: Int) {
        guard let player else { return }
        var sawPlaying = false
        playerObservation = player.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                guard token == self.observationToken else { return }
                switch state {
                case .playing:
                    sawPlaying = true
                    self.isSpeaking = true
                case .idle:
                    // Ignore the initial .idle before any chunk has
                    // been enqueued (S11 race: subscribe fires the
                    // current state synchronously).
                    if self.awaitingFirstChunk { return }
                    if sawPlaying {
                        self.isSpeaking = false
                        self.audioDidComplete(token: token)
                    }
                case .paused:
                    break
                }
            }
    }

    private func startFallbackTimer(duration: TimeInterval, token: Int) {
        // S11 AC #5: hard cap at 30s even if a slide's fallback says less.
        // We use the *larger* of slide.fallbackDuration and a buffer so
        // audio has time to play. 1.6× buffer keeps short slides snappy.
        let cap: TimeInterval = 30
        let target = min(max(duration * 1.6, duration + 2), cap)
        fallbackTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(target * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            guard token == self.observationToken else { return }
            if case .showing = self.phase {
                self.audioDidComplete(token: token)
            }
        }
    }

    private func audioDidComplete(token: Int) {
        guard token == observationToken else { return }
        guard case .showing(let i) = phase else { return }
        // Final slide doesn't auto-advance — user must click Get Started.
        if slides[i].isFinal { return }
        advance()
    }

    /// Decode a WAV blob into an AVAudioPCMBuffer. Mirrors
    /// AppDispatcher.decodeWAV — duplicated so this module doesn't
    /// take a hard dep on AppDispatcher.
    private func decodeWAV(_ data: Data) async -> AVAudioPCMBuffer? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-onboarding-\(UUID().uuidString).wav")
        do {
            try data.write(to: tmp)
            let file = try AVAudioFile(forReading: tmp)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            try file.read(into: buffer)
            try? FileManager.default.removeItem(at: tmp)
            return buffer
        } catch {
            log.error("onboarding decodeWAV: \(error)")
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }

    /// Fire the macOS Accessibility-permission TCC prompt. Re-uses the
    /// same primitive AppDelegate.promptForAccessibilityIfNeeded does
    /// so behaviour stays consistent.
    private func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        log.info("onboarding: AXIsProcessTrusted=\(trusted)")
    }
}
