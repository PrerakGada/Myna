// PlaygroundTakesView.swift — the list of takes: a row per take, and a
// card per comparison with its takes side by side.
//
// Every take can be played, scrubbed, saved in any format this Mac can
// encode, dragged out as a file (grab the text or the voice name — the
// waveform itself is for scrubbing), copied, shown in Finder, reused, or
// deleted. Clicking a take selects it for Space and ⌘S.
import SwiftUI

struct PlaygroundTakesSection: View {
    @ObservedObject var model: PlaygroundModel
    @ObservedObject var store: PlaygroundTakeStore
    @ObservedObject var player: PlaygroundPlayer

    @State private var confirmingDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DashSectionTitle("Takes")
                Text("\(store.takes.count) of \(PlaygroundTakeStore.maxTakes) kept")
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.tertiary)
                    .help("The oldest take is deleted when a new one would make more than \(PlaygroundTakeStore.maxTakes).")
                Spacer(minLength: 8)
                if !store.takes.isEmpty {
                    Button("Delete All…", role: .destructive) { confirmingDeleteAll = true }
                        .buttonStyle(.borderless)
                        .foregroundStyle(DashboardDesign.secondary)
                }
            }

            if store.recoveredCount > 0 {
                Text("\(store.recoveredCount) \(store.recoveredCount == 1 ? "take was" : "takes were") recovered "
                    + "from audio on disk after the list was damaged. Their text couldn't be recovered.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = player.lastError {
                Text(error)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.negative)
            }

            if store.takes.isEmpty {
                DashCard {
                    DashEmptyState(
                        systemImage: "waveform",
                        title: "No takes yet",
                        message: "Type something above and press ⌘↩. Every take is kept here, with its voice "
                            + "and speed, until you delete it or it becomes one of more than "
                            + "\(PlaygroundTakeStore.maxTakes)."
                    )
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(PlaygroundTakeSection.sections(from: store.takes)) { section in
                        switch section {
                        case .single(let take):
                            PlaygroundTakeRow(take: take, model: model, player: player)
                        case .comparison(_, let takes):
                            PlaygroundComparisonCard(takes: takes, model: model, player: player)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete all \(store.takes.count) takes?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All Takes", role: .destructive) { model.deleteAllTakes() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their audio is deleted from this Mac. Files you saved elsewhere are not touched.")
        }
    }
}

// MARK: - single take

struct PlaygroundTakeRow: View {
    let take: PlaygroundTake
    @ObservedObject var model: PlaygroundModel
    @ObservedObject var player: PlaygroundPlayer

    @State private var isHovering = false

    private var isSelected: Bool { model.selectedTakeId == take.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PlaygroundPlayButton(isPlaying: player.isPlaying(take.id)) {
                PlaygroundFocus.releaseEditor()
                model.togglePlay(take)
            }
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(take.snippet())
                            .font(DashboardDesign.bodyFont)
                            .foregroundStyle(take.text.isEmpty ? DashboardDesign.secondary : DashboardDesign.title)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(take.createdAt.formatted(.relative(presentation: .named)))
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(PlaygroundTakeFormat.details(take, engineName: model.engineName(for: take)))
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onDrag { PlaygroundExport.dragProvider(for: model.shareableFile(for: take)) }
                .help("Drag to Finder or another app to copy the audio file")

                PlaygroundTakeWaveform(take: take, model: model, player: player, height: 30)
            }
            HStack(spacing: 2) {
                PlaygroundSaveMenu(take: take, model: model, compact: false)
                PlaygroundTakeMenu(takes: [take], model: model)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .fill(isSelected ? DashboardDesign.cardRaised : (isHovering ? Color.white.opacity(0.045) : DashboardDesign.card))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? DashboardDesign.accent.opacity(0.45) : DashboardDesign.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            PlaygroundFocus.releaseEditor()
            model.select(take)
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - comparison

struct PlaygroundComparisonCard: View {
    let takes: [PlaygroundTake]
    @ObservedObject var model: PlaygroundModel
    @ObservedObject var player: PlaygroundPlayer

    var body: some View {
        DashCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "square.split.2x1")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DashboardDesign.accent)
                    Text("Comparison")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DashboardDesign.title)
                    Text(takes.first?.snippet(limit: 80) ?? "")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let first = takes.first {
                        Text(first.createdAt.formatted(.relative(presentation: .named)))
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    PlaygroundTakeMenu(takes: takes, model: model)
                }
                // Equal heights, so the waveforms line up for A/B even when
                // one voice's name wraps.
                HStack(alignment: .top, spacing: 10) {
                    ForEach(takes) { take in
                        PlaygroundCompareCell(take: take, model: model, player: player)
                            .frame(maxHeight: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PlaygroundCompareCell: View {
    let take: PlaygroundTake
    @ObservedObject var model: PlaygroundModel
    @ObservedObject var player: PlaygroundPlayer

    private var isSelected: Bool { model.selectedTakeId == take.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PlaygroundPlayButton(isPlaying: player.isPlaying(take.id), size: 24) {
                    PlaygroundFocus.releaseEditor()
                    model.togglePlay(take)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(take.voiceLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardDesign.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // The duration is on the clock below; this says how long it took.
                    if let ms = take.renderMs {
                        ViewThatFits(in: .horizontal) {
                            Text("made in \(PlaygroundText.renderTimeLabel(ms: ms))")
                            Text(PlaygroundText.renderTimeLabel(ms: ms))
                        }
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                        .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onDrag { PlaygroundExport.dragProvider(for: model.shareableFile(for: take)) }
                .help("Drag to Finder or another app to copy the audio file")
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            PlaygroundTakeWaveform(take: take, model: model, player: player, height: 34, showsClock: false)
            HStack(spacing: 2) {
                PlaygroundClock(take: take, player: player, compact: true)
                Spacer(minLength: 0)
                PlaygroundSaveMenu(take: take, model: model, compact: true)
                PlaygroundTakeMenu(takes: [take], model: model)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? DashboardDesign.cardRaised : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? DashboardDesign.accent.opacity(0.45) : DashboardDesign.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            PlaygroundFocus.releaseEditor()
            model.select(take)
        }
    }
}

// MARK: - shared pieces

struct PlaygroundPlayButton: View {
    let isPlaying: Bool
    var size: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isPlaying ? Color.white : DashboardDesign.title)
                .frame(width: size, height: size)
                .background(Circle().fill(isPlaying ? DashboardDesign.accent : Color.white.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause (Space)" : "Play (Space)")
        .accessibilityLabel(isPlaying ? "Pause take" : "Play take")
    }
}

struct PlaygroundSaveMenu: View {
    let take: PlaygroundTake
    @ObservedObject var model: PlaygroundModel
    let compact: Bool

    var body: some View {
        Menu {
            ForEach(model.formats) { format in
                Button(Self.itemTitle(format)) { model.save(take, as: format) }
                    .disabled(!format.available)
            }
        } label: {
            if compact {
                Image(systemName: "square.and.arrow.down")
            } else {
                Label("Save", systemImage: "square.and.arrow.down")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .disabled(model.isSaving)
        .help("Save this take as an audio file (⌘S uses the last format)")
        .accessibilityLabel("Save take")
    }

    nonisolated static func itemTitle(_ format: AudioFormatInfo) -> String {
        if format.available { return "\(format.label)…" }
        return "\(format.label) — \(format.reason ?? "not available on this Mac")"
    }
}

/// The "…" menu. One take, or every take of a comparison.
struct PlaygroundTakeMenu: View {
    let takes: [PlaygroundTake]
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        Menu {
            if let take = takes.first, takes.count == 1 {
                Button("Copy Audio File") { model.copyAudio(take) }
                Button("Copy Text") { model.copyText(take) }
                    .disabled(take.text.isEmpty)
                Button("Show in Finder") { model.reveal(take) }
                Divider()
                Button("Use This Text") { model.useText(of: take) }
                    .disabled(take.text.isEmpty)
                Button("Use This Voice") { model.useVoice(of: take) }
                    .disabled(!model.voices.contains { $0.id == take.voice })
                Divider()
                Button("Delete Take", role: .destructive) { model.delete([take]) }
            } else if let first = takes.first {
                Button("Use This Text") { model.useText(of: first) }
                    .disabled(first.text.isEmpty)
                Divider()
                Button("Delete Comparison", role: .destructive) { model.delete(takes) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }
}

/// The metadata lines under a take.
enum PlaygroundTakeFormat {
    /// "Heart (female) · 1.25× · 0:12 · rendered in 1.8 s · Kokoro"
    static func details(_ take: PlaygroundTake, engineName: String?) -> String {
        var parts = [take.voiceLabel]
        if !take.isRecovered {
            parts.append(take.speed.map(PlaygroundText.speedLabel) ?? "engine's own pace")
        }
        parts.append(PlaygroundText.clock(take.durationS))
        if let ms = take.renderMs { parts.append("rendered in \(PlaygroundText.renderTimeLabel(ms: ms))") }
        if let engineName, engineName != take.voiceLabel { parts.append(engineName) }
        return parts.joined(separator: " · ")
    }
}
