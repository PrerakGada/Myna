// PlaygroundWaveformView.swift — a take's waveform with a playhead you
// can click or drag to move.
//
// Drawn with Canvas from the peaks stored in the take's index entry, so a
// list of fifty takes never reads audio back from disk. The played part
// is in the accent colour. While a take plays, a TimelineView redraws only
// that take's strip; every other strip is static.
import SwiftUI

struct PlaygroundWaveform: View {
    let peaks: [Float]
    /// 0…1.
    let progress: Double
    /// Draw the playhead line (the take is loaded, playing or paused).
    let showsPlayhead: Bool
    let onSeek: (Double) -> Void

    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                Self.draw(peaks: peaks, progress: progress, showsPlayhead: showsPlayhead, in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(PlaygroundWaveformMath.fraction(x: value.location.x, width: width))
                    }
            )
        }
        .help("Click or drag to move the playhead")
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(1, progress + 0.1))
            case .decrement: onSeek(max(0, progress - 0.1))
            @unknown default: break
            }
        }
    }

    private static func draw(
        peaks: [Float],
        progress: Double,
        showsPlayhead: Bool,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width > 0, size.height > 0 else { return }
        let fit = max(1, Int(size.width / (barWidth + barGap)))
        let bars = PlaygroundWaveformMath.resample(peaks, to: fit)
        let headX = size.width * CGFloat(max(0, min(1, progress)))

        if bars.isEmpty {
            let line = CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)
            context.fill(Path(line), with: .color(Color.white.opacity(0.2)))
        } else {
            let step = size.width / CGFloat(bars.count)
            let width = max(1, min(barWidth * 2, step - barGap))
            var played = Path()
            var rest = Path()
            for (index, level) in bars.enumerated() {
                let x = CGFloat(index) * step
                // Slight lift so quiet syllables stay visible next to loud ones.
                let height = max(2, CGFloat(pow(Double(level), 0.8)) * size.height)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                if x + width / 2 <= headX {
                    played.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                } else {
                    rest.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
                }
            }
            context.fill(rest, with: .color(Color.white.opacity(0.26)))
            context.fill(played, with: .color(DashboardDesign.accent))
        }

        if showsPlayhead {
            let head = CGRect(x: min(size.width - 1.5, max(0, headX - 0.75)), y: 0, width: 1.5, height: size.height)
            context.fill(Path(head), with: .color(Color.white.opacity(0.9)))
        }
    }
}

/// A take's waveform wired to the Playground's player, with its clock.
struct PlaygroundTakeWaveform: View {
    let take: PlaygroundTake
    let model: PlaygroundModel
    @ObservedObject var player: PlaygroundPlayer
    var height: CGFloat = 30
    var showsClock = true

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if player.isPlaying(take.id) {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                        waveform
                    }
                } else {
                    waveform
                }
            }
            .frame(height: height)
            if showsClock {
                PlaygroundClock(take: take, player: player)
            }
        }
    }

    private var waveform: some View {
        PlaygroundWaveform(
            peaks: take.peaks,
            progress: player.progress(for: take.id),
            showsPlayhead: player.currentId == take.id,
            onSeek: { fraction in
                PlaygroundFocus.releaseEditor()
                model.seek(take, to: fraction)
            }
        )
    }
}

/// "0:04 / 0:12", ticking while the take plays.
struct PlaygroundClock: View {
    let take: PlaygroundTake
    @ObservedObject var player: PlaygroundPlayer
    /// In a narrow comparison cell the clock may shrink rather than push
    /// the save and "…" buttons out of the cell.
    var compact = false

    var body: some View {
        if player.isPlaying(take.id) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                label
            }
        } else {
            label
        }
    }

    private var label: some View {
        Text("\(PlaygroundText.clock(player.time(for: take.id))) / \(PlaygroundText.clock(take.durationS))")
            .font(DashboardDesign.captionFont.monospacedDigit())
            .foregroundStyle(DashboardDesign.secondary)
            .lineLimit(1)
            .minimumScaleFactor(compact ? 0.7 : 1)
            .fixedSize(horizontal: !compact, vertical: false)
    }
}
