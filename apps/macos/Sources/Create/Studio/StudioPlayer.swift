// StudioPlayer.swift — plays a finished render inside the pane.
//
// Deliberately not Myna's AudioPlayer: that one drives the pill, the
// karaoke ribbon and the menu-bar state, and a file you made is not a
// read. AVAudioPlayer streams from disk, so a ten-hour book doesn't load
// into memory.
//
// No AVAudioPlayerDelegate: its callbacks arrive on an AVFoundation queue,
// the trap documented in AudioPlayer.swift (a closure isolated to the main
// actor, run off it, kills the app on macOS 26). A main-actor task ticks
// four times a second instead, which also drives the scrubber. The clock
// is its own object so only the scrubber redraws on every tick.
import AVFoundation
import SwiftUI

@MainActor
final class StudioPlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
}

@MainActor
final class StudioPlayer: ObservableObject {
    static let shared = StudioPlayer()

    @Published private(set) var jobId: String?
    @Published private(set) var title = ""
    @Published private(set) var chapters: [RenderChapter] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var error: String?
    let clock = StudioPlaybackClock()

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// Play/pause for a row's button: loads the job if it isn't the
    /// current one.
    func toggle(_ job: RenderJob) {
        if job.id == jobId, player != nil {
            if isPlaying { pause() } else { resume() }
        } else {
            play(job, from: 0)
        }
    }

    func play(_ job: RenderJob, from start: Double) {
        guard let url = job.fileURL else { return }
        if job.id != jobId || player == nil {
            guard FileManager.default.fileExists(atPath: url.path) else {
                error = "The audio file for “\(job.title)” is missing. It may have been moved or deleted in Finder."
                return
            }
            do {
                let loaded = try AVAudioPlayer(contentsOf: url)
                loaded.prepareToPlay()
                stopTicker()
                player?.stop()
                player = loaded
                jobId = job.id
                title = job.title
                chapters = job.chapters ?? []
                duration = loaded.duration
                error = nil
            } catch {
                self.error = "Couldn't play “\(job.title)”: \(error.localizedDescription)"
                return
            }
        }
        seek(to: start)
        resume()
    }

    func resume() {
        guard let player else { return }
        if player.currentTime >= player.duration - 0.25 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        tick()
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = min(max(0, time), max(0, player.duration - 0.05))
        clock.currentTime = player.currentTime
    }

    func skip(by seconds: Double) {
        seek(to: clock.currentTime + seconds)
    }

    func jump(toChapter index: Int) {
        guard chapters.indices.contains(index) else { return }
        seek(to: chapters[index].startS)
        if !isPlaying { resume() }
    }

    /// Unloads the file. Also used when the job it belongs to is deleted.
    func close() {
        stopTicker()
        player?.stop()
        player = nil
        jobId = nil
        title = ""
        chapters = []
        duration = 0
        isPlaying = false
        clock.currentTime = 0
    }

    /// The chapter the playhead is in.
    var currentChapterIndex: Int? {
        StudioPlayer.chapterIndex(at: clock.currentTime, in: chapters)
    }

    static func chapterIndex(at time: Double, in chapters: [RenderChapter]) -> Int? {
        chapters.lastIndex { $0.startS <= time + 0.01 }
    }

    // MARK: - ticking

    private func startTicker() {
        stopTicker()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        clock.currentTime = player.currentTime
        if isPlaying && !player.isPlaying {
            // Reached the end.
            isPlaying = false
            stopTicker()
        }
    }
}

/// The bar under the library while something is loaded.
struct StudioPlayerBar: View {
    @ObservedObject var player: StudioPlayer

    var body: some View {
        DashCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button { player.skip(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                    }
                    .buttonStyle(.plain)
                    .help("Back 15 seconds")
                    .accessibilityLabel("Back 15 seconds")

                    Button {
                        if player.isPlaying { player.pause() } else { player.resume() }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(DashboardDesign.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button { player.skip(by: 30) } label: {
                        Image(systemName: "goforward.30")
                    }
                    .buttonStyle(.plain)
                    .help("Forward 30 seconds")
                    .accessibilityLabel("Forward 30 seconds")

                    StudioNowPlayingTitle(player: player, clock: player.clock)

                    Spacer(minLength: 8)

                    if player.chapters.count > 1 {
                        Menu {
                            ForEach(Array(player.chapters.enumerated()), id: \.offset) { index, chapter in
                                Button("\(StudioFormat.clock(chapter.startS))  \(chapter.title)") {
                                    player.jump(toChapter: index)
                                }
                            }
                        } label: {
                            Label("Chapters", systemImage: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Button { player.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DashboardDesign.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop and close the player")
                    .accessibilityLabel("Close player")
                }
                .foregroundStyle(DashboardDesign.body)

                StudioScrubber(player: player, clock: player.clock)
            }
        }
    }
}

private struct StudioNowPlayingTitle: View {
    @ObservedObject var player: StudioPlayer
    @ObservedObject var clock: StudioPlaybackClock

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.title)
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.title)
                .lineLimit(1)
            if let index = StudioPlayer.chapterIndex(at: clock.currentTime, in: player.chapters),
               player.chapters.count > 1 {
                Text("Chapter \(index + 1) of \(player.chapters.count): \(player.chapters[index].title)")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// Slider plus elapsed and remaining time. While the thumb is held the
/// ticker doesn't move it; the seek happens on release.
private struct StudioScrubber: View {
    @ObservedObject var player: StudioPlayer
    @ObservedObject var clock: StudioPlaybackClock
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(StudioFormat.clock(shown))
                .frame(minWidth: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { shown }, set: { scrubValue = $0 }),
                in: 0...max(1, player.duration),
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = clock.currentTime
                        scrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        scrubbing = false
                    }
                }
            )
            .controlSize(.small)
            .accessibilityLabel("Position")
            Text("-" + StudioFormat.clock(max(0, player.duration - shown)))
                .frame(minWidth: 50, alignment: .leading)
        }
        .font(DashboardDesign.captionFont.monospacedDigit())
        .foregroundStyle(DashboardDesign.secondary)
    }

    private var shown: Double { scrubbing ? scrubValue : clock.currentTime }
}
