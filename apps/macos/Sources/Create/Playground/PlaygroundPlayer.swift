// PlaygroundPlayer.swift — plays Playground takes, and nothing else.
//
// Deliberately not the app's AudioPlayer. That one is the read pipeline:
// it drives the pill, the karaoke ribbon, the menu-bar state and History,
// and a take is not a read. This is a plain AVAudioPlayer over the take's
// WAV, so a take can play while a read is speaking and stopping one never
// touches the other. Starting a take stops the previous take only.
//
// No AVAudioPlayerDelegate: its callbacks are an off-main hazard for a
// @MainActor type on macOS 26 (see the AudioPlayer crash in v0.4.0).
// End of playback is noticed by a short poll on the main actor instead,
// and the playhead is read straight from the player by a TimelineView
// while a take plays, so nothing publishes thirty times a second.
import AVFoundation
import Foundation

@MainActor
final class PlaygroundPlayer: ObservableObject {

    /// The take loaded into the player, playing or paused.
    @Published private(set) var currentId: String?
    @Published private(set) var isPlaying = false
    /// Bumped on seek, pause and finish so a paused playhead redraws.
    @Published private(set) var revision = 0
    @Published private(set) var lastError: String?

    private var player: AVAudioPlayer?
    private var watcher: Task<Void, Never>?

    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    func isPlaying(_ id: String) -> Bool {
        isPlaying && currentId == id
    }

    /// 0…1 through the take, or 0 for a take that isn't loaded.
    func progress(for id: String) -> Double {
        guard id == currentId, let player, player.duration > 0 else { return 0 }
        return max(0, min(1, player.currentTime / player.duration))
    }

    func time(for id: String) -> TimeInterval {
        id == currentId ? currentTime : 0
    }

    func toggle(id: String, url: URL) {
        if id == currentId, let player {
            if player.isPlaying { pause() } else { resume() }
        } else {
            play(id: id, url: url)
        }
    }

    func play(id: String, url: URL) {
        guard load(id: id, url: url) else { return }
        player?.currentTime = 0
        resume()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        watcher?.cancel()
        watcher = nil
        revision += 1
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        player?.stop()
        player = nil
        currentId = nil
        isPlaying = false
        revision += 1
    }

    /// Moves the playhead. Seeking a take that isn't loaded loads it
    /// paused at that point, so play picks up from where you clicked.
    func seek(id: String, url: URL, to fraction: Double) {
        guard load(id: id, url: url), let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        revision += 1
    }

    /// Called before a take's audio is deleted.
    func release(id: String) {
        if id == currentId { stop() }
    }

    // MARK: - private

    private func resume() {
        guard let player else { return }
        if player.play() {
            isPlaying = true
            lastError = nil
            startWatching()
        } else {
            isPlaying = false
            lastError = "This take couldn't be played."
        }
    }

    private func load(id: String, url: URL) -> Bool {
        if id == currentId, player != nil { return true }
        stop()
        do {
            let fresh = try AVAudioPlayer(contentsOf: url)
            fresh.prepareToPlay()
            player = fresh
            currentId = id
            lastError = nil
            return true
        } catch {
            lastError = "This take's audio couldn't be opened. It may have been deleted from disk."
            return false
        }
    }

    /// Notices the end of playback. AVAudioPlayer rewinds itself to 0
    /// when it runs out, which is where the playhead should go too.
    private func startWatching() {
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let player = self.player else { return }
                if self.isPlaying, !player.isPlaying {
                    self.isPlaying = false
                    self.revision += 1
                    return
                }
            }
        }
    }
}
