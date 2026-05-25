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
import AVFoundation
import Foundation

@MainActor
public final class AppDispatcher: URLSchemeDispatching {
    private let client: DaemonClient
    private let player: AudioPlayer
    private let selection: SelectionService
    private let chrome: ChromeService
    private let settings: SettingsViewModel
    private let log = Log(.app)

    public init(
        client: DaemonClient,
        player: AudioPlayer,
        selection: SelectionService,
        chrome: ChromeService,
        settings: SettingsViewModel
    ) {
        self.client = client
        self.player = player
        self.selection = selection
        self.chrome = chrome
        self.settings = settings
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
        let req = SynthesizeRequest(
            text: text,
            url: url,
            voice: settings.voice,
            speed: settings.defaultSpeed,
            mode: mode,
            sessionId: UUID().uuidString
        )
        do {
            for try await chunk in client.synthesize(req) {
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
