// APITryItModel.swift — the API pane's "Try it" box: send one real
// request to POST /v1/audio/speech through RenderClient, the same
// endpoint an OpenAI client hits, and play what comes back.
//
// Playback uses its own AVAudioPlayer, not the app's AudioPlayer: a
// render is not a read, so it must not drive the menu-bar state, the pill
// or History. No AVAudioPlayer delegate either — its callbacks are the
// kind of system callback that has crashed this app on macOS 26 when a
// @MainActor closure receives them — so the end of playback is noticed by
// a short main-actor poll instead.
import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class APITryItModel: ObservableObject {

    struct Take: Equatable {
        let format: String
        let bytes: Int
        /// Wall time for the whole request, as a client would see it.
        let wallMs: Int
        let durationS: Double?
        let voice: String?
        let engine: String?
        let playable: Bool
    }

    enum Phase: Equatable {
        case idle
        case running
        case done(Take)
        case failed(String)
    }

    /// Formats AVAudioPlayer can open from memory. Opus comes back in an
    /// Ogg container and PCM has no header, so those can be saved but not
    /// previewed here.
    static let playableFormats: Set<String> = ["wav", "mp3", "aac", "m4a", "flac"]

    @Published var text = "Hello from Myna. This clip came from the OpenAI-compatible endpoint on this Mac."
    /// Empty means "don't send a voice": the engine's default.
    @Published var voice = ""
    @Published var format = "wav"
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPlaying = false
    /// Play each take as soon as it arrives. Off only for offscreen
    /// layout snapshots, which must not touch the audio device.
    var autoPlay = true

    private let render: RenderClient
    private var audio: Data?
    private var player: AVAudioPlayer?
    private var runTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    init(render: RenderClient) {
        self.render = render
    }

    /// Set once the user picks a format, so a later formats refresh
    /// doesn't override their choice.
    private var formatChosen = false

    var isRunning: Bool { phase == .running }

    func chooseFormat(_ id: String) {
        format = id
        formatChosen = true
    }

    /// Follow the pane's preferred format until the user picks one, and
    /// never sit on a format this Mac can no longer encode.
    func adoptDefaultFormat(_ preferred: String, available formats: [AudioFormatInfo]) {
        let usable = Set(formats.filter(\.available).map(\.id))
        if !formatChosen || !usable.contains(format) {
            format = preferred
        }
    }

    var canRun: Bool {
        !isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func run() {
        guard canRun else { return }
        stop()
        runTask?.cancel()
        phase = .running
        let request = SpeechRequest(
            input: text,
            voice: voice.isEmpty ? nil : voice,
            responseFormat: format
        )
        let format = format
        runTask = Task { [weak self, render] in
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let result = try await render.speech(request)
                let elapsed = clock.now - started
                self?.finish(result, format: format, elapsed: elapsed)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func play() {
        guard let audio, case .done(let take) = phase, take.playable else { return }
        stop()
        do {
            let player = try AVAudioPlayer(data: audio)
            player.prepareToPlay()
            guard player.play() else { return }
            self.player = player
            isPlaying = true
            watchPlayback()
        } catch {
            phase = .failed("The audio came back but couldn't be played here: \(error.localizedDescription)")
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// Save the last take with a save panel.
    func save() {
        guard let audio, case .done(let take) = phase else { return }
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: take.format) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "myna-speech.\(take.format)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try audio.write(to: url, options: .atomic)
        } catch {
            phase = .failed("Couldn't save the file: \(error.localizedDescription)")
        }
    }

    // MARK: - private

    private func finish(_ result: SpeechResult, format: String, elapsed: Duration) {
        let parts = elapsed.components
        let wallMs = Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        audio = result.audio
        phase = .done(Take(
            format: format,
            bytes: result.audio.count,
            wallMs: wallMs,
            durationS: result.durationS,
            voice: result.voice,
            engine: result.engine,
            playable: Self.playableFormats.contains(format)
        ))
        if autoPlay { play() }
    }

    private func watchPlayback() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                if self.player?.isPlaying != true {
                    self.isPlaying = false
                    self.player = nil
                    return
                }
            }
        }
    }
}
