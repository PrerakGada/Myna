// EngineCards.swift — one engine in the Engine page's library, and the
// panel its hover (or ⓘ) opens with every measured number, each compared
// against the other engines. Numbers come from the daemon's catalog
// (daemon/myna/engines.py), measured in the Phase 0 bake-off.
import SwiftUI

// MARK: - Engine card

struct EngineCard: View {
    let engine: EngineEntry
    let all: [EngineEntry]
    let isSwitching: Bool
    let isBusy: Bool
    let error: String?
    let onDownload: () -> Void
    let onUse: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false
    @State private var showDetails = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(engine.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DashboardDesign.title)
                if engine.active {
                    DashBadge("In use", tint: DashboardDesign.positive)
                } else if let badge = engine.badge {
                    DashBadge(badge, tint: DashboardDesign.info)
                }
                Spacer(minLength: 4)
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(DashboardDesign.secondary)
                }
                .buttonStyle(.plain)
                .help("Measured numbers for \(engine.name)")
                .accessibilityLabel("Details for \(engine.name)")
            }
            Text(engine.tagline)
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                keyFigure(EngineFormat.seconds(engine.stats.firstWordS), "first word")
                keyFigure(EngineFormat.memory(engine.stats.peakMemoryMb), "peak memory")
                keyFigure(EngineFormat.percent(engine.stats.wordErrorPct), "word errors")
                keyFigure(EngineFormat.size(engine.diskMb ?? Double(engine.downloadMb)), "on disk")
            }

            Spacer(minLength: 0)
            actionRow
            if let error {
                Text(error)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DashboardDesign.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .fill(hovering ? DashboardDesign.cardRaised : DashboardDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(
                    engine.active ? DashboardDesign.positive.opacity(0.45) : DashboardDesign.border,
                    lineWidth: 1
                )
        )
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            if inside {
                // A short delay so sweeping the pointer across the grid
                // doesn't flash every popover.
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if !Task.isCancelled { showDetails = true }
                }
            } else {
                showDetails = false
            }
        }
        .popover(isPresented: $showDetails, arrowEdge: .trailing) {
            EngineDetails(engine: engine, all: all)
        }
    }

    private func keyFigure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(DashboardDesign.body)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DashboardDesign.tertiary)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            switch engine.state {
            case .installed:
                if engine.active {
                    Label("Speaking now", systemImage: "waveform")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.positive)
                } else if isSwitching {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                } else {
                    Button("Use \(engine.name)", action: onUse)
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy)
                }
                Spacer()
                if !engine.active && engine.id != "kokoro" && !isSwitching {
                    Button("Remove", action: onRemove)
                        .buttonStyle(.borderless)
                        .foregroundStyle(DashboardDesign.secondary)
                        .disabled(isBusy)
                }
            case .downloading:
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: engine.progress ?? 0)
                    Text(downloadCaption)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .monospacedDigit()
                }
            case .failed, .notInstalled:
                Button {
                    onDownload()
                } label: {
                    Label(
                        engine.state == .failed ? "Try again" : "Download · \(EngineFormat.size(Double(engine.downloadMb)))",
                        systemImage: "arrow.down.circle"
                    )
                }
                if engine.state == .failed, let message = engine.error {
                    Text(message)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.negative)
                        .lineLimit(2)
                        .help(message)
                }
                Spacer()
            }
        }
    }

    private var downloadCaption: String {
        let done = EngineFormat.size(engine.downloadedMb ?? 0)
        let total = EngineFormat.size(engine.totalMb ?? Double(engine.downloadMb))
        return "Downloading · \(done) of \(total)"
    }
}

// MARK: - Hover details

private struct EngineDetails: View {
    let engine: EngineEntry
    let all: [EngineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.name)
                    .font(.system(size: 15, weight: .semibold))
                Text("\(engine.maker) · \(engine.params) parameters · \(engine.license)")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(.secondary)
                Text(engine.description)
                    .font(DashboardDesign.bodyFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 10) {
                MetricRow(
                    title: "Wait for the first word",
                    value: EngineFormat.seconds(engine.stats.firstWordS),
                    explanation: "How long a new read takes to start speaking.",
                    fraction: fraction(\.stats.firstWordS),
                    lowerIsBetter: true,
                    isBest: isBest(\.stats.firstWordS, lowerIsBetter: true, within: 0.02)
                )
                MetricRow(
                    title: "Speed",
                    value: "\(EngineFormat.multiple(engine.stats.speedX)) real time",
                    explanation: "Seconds of speech made per second of work. Anything above 1× keeps ahead of playback.",
                    fraction: fraction(\.stats.speedX),
                    lowerIsBetter: false,
                    isBest: isBest(\.stats.speedX, lowerIsBetter: false, within: 0.05, relative: true)
                )
                MetricRow(
                    title: "Peak memory",
                    value: EngineFormat.memory(engine.stats.peakMemoryMb),
                    explanation: "The most memory it used reading a long paragraph. Lower leaves more room for your other apps.",
                    fraction: fraction(\.stats.peakMemoryMb),
                    lowerIsBetter: true,
                    isBest: isBest(\.stats.peakMemoryMb, lowerIsBetter: true, within: 0.05, relative: true)
                )
                MetricRow(
                    title: "Word errors",
                    value: EngineFormat.percent(engine.stats.wordErrorPct),
                    explanation: "Words a transcription check misheard. A point or two apart is a tie.",
                    fraction: fraction(\.stats.wordErrorPct),
                    lowerIsBetter: true,
                    isBest: isBest(\.stats.wordErrorPct, lowerIsBetter: true, within: 1)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                fact("Languages", engine.languages.joined(separator: ", "))
                fact("Voices", EngineFormat.voices(engine))
                fact("Download", EngineFormat.size(Double(engine.downloadMb)))
                fact("Audio", "\(engine.sampleRate / 1000) kHz")
                fact("Default speed", engine.nativeSpeed
                     ? "Follows your default speed setting."
                     : "Ignores the default speed setting. The speed buttons during playback still work.")
                if let stream = engine.stats.streamFirstS {
                    fact("If streamed", "Could start in \(EngineFormat.seconds(stream)). Myna doesn't stream yet.")
                }
                if let credit = engine.credit {
                    fact("Credit", credit)
                }
            }

            Text("Measured on \(engine.stats.measuredOn). Your Mac may differ.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 380)
    }

    /// Position of this engine's value between 0 and the largest value any
    /// engine has, so the bar reads as "compared with the others".
    private func fraction(_ key: KeyPath<EngineEntry, Double>) -> Double {
        let top = all.map { $0[keyPath: key] }.max() ?? 0
        return top > 0 ? engine[keyPath: key] / top : 0
    }

    /// Best of the catalog on this measure, counting near-ties as best too
    /// (0.10 s vs 0.10 s, or 3% vs 4% word errors, is not a real difference).
    private func isBest(
        _ key: KeyPath<EngineEntry, Double>, lowerIsBetter: Bool, within: Double, relative: Bool = false
    ) -> Bool {
        let values = all.map { $0[keyPath: key] }
        guard let best = lowerIsBetter ? values.min() : values.max() else { return false }
        let mine = engine[keyPath: key]
        let tolerance = relative ? best * within : within
        return abs(mine - best) <= tolerance + 1e-9
    }

    private func fact(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(text)
                .font(DashboardDesign.captionFont)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let explanation: String
    let fraction: Double
    let lowerIsBetter: Bool
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                if isBest {
                    DashBadge("Best", tint: DashboardDesign.positive)
                }
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(isBest ? DashboardDesign.positive : Color.accentColor.opacity(0.8))
                        .frame(width: max(4, geo.size.width * min(1, fraction)))
                }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text(explanation + (lowerIsBetter ? " Shorter bar is better." : " Longer bar is better."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Formatting

enum EngineFormat {
    static func seconds(_ s: Double) -> String {
        s < 1 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }

    static func memory(_ mb: Double) -> String {
        mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : String(format: "%.0f MB", mb)
    }

    static func size(_ mb: Double) -> String { memory(mb) }

    static func percent(_ pct: Double) -> String { String(format: "%.0f%%", pct) }

    static func multiple(_ x: Double) -> String { String(format: "%.0f×", x) }

    /// "41 built-in, and blends of them" — what there is to choose from.
    static func voices(_ engine: EngineEntry) -> String {
        let count = engine.voices.count
        var text = count == 1 ? "One built-in voice" : "\(count) built-in"
        if engine.cloning {
            text += ", plus any voice copied from a recording"
        } else if engine.blending == true {
            text += ", and blends of them"
        } else if count == 1 {
            text += ". It is a single-speaker model"
        }
        return text + "."
    }
}
