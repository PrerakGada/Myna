// TranscriptPanelView.swift — the transcript panel's content.
//
// One sentence per row, like a lyrics view: the sentence being read is lit
// in the accent colour, the ones already read are dimmest, the ones to come
// a step brighter. Click any sentence to play from it. The view keeps the
// lit sentence in the middle of the scroll area, but holds off for a few
// seconds after the user scrolls by hand (TranscriptScrollState).
//
// Timing inside a chunk is estimated (SentenceTiming), so the light can sit
// a moment ahead of or behind the voice mid-chunk; it is exact at chunk
// boundaries. The copy says "sentence", never "word", on purpose.
import SwiftUI

struct TranscriptPanelView: View {
    @ObservedObject var store: TranscriptStore
    let scroll: TranscriptScrollState

    var body: some View {
        VStack(spacing: 0) {
            if let transcript = store.transcript {
                header(transcript)
                separator
                sentences(transcript)
                separator
                TranscriptTransport(store: store)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        .background(DashboardDesign.surface)
        .preferredColorScheme(.dark)
    }

    private var separator: some View {
        Rectangle().fill(DashboardDesign.separator).frame(height: 1)
    }

    // MARK: - header

    private func header(_ transcript: Transcript) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transcript.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DashboardDesign.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Image(systemName: transcript.source.systemImage)
                        .font(.system(size: 10))
                    Text(sourceLine(transcript))
                        .lineLimit(1)
                    if let queued = store.queuedLabel {
                        Text("\u{00B7} \(queued)")
                            .foregroundStyle(DashboardDesign.accent)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(DashboardDesign.secondary)
            }
            Spacer(minLength: 8)
            TranscriptStatusChip(status: status(transcript))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sourceLine(_ transcript: Transcript) -> String {
        guard let app = transcript.appName, !app.isEmpty, transcript.source != .article else {
            return transcript.source.label
        }
        return "\(transcript.source.label) \u{00B7} \(app)"
    }

    private func status(_ transcript: Transcript) -> TranscriptStatusChip.Status {
        switch transcript.ending {
        case .finished: return .finished
        case .stopped: return .stopped
        case nil: break
        }
        switch store.playback {
        case .playing: return .playing
        case .paused: return .paused
        case .preparing, .idle: return .preparing
        }
    }

    // MARK: - sentences

    private func sentences(_ transcript: Transcript) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Color.clear.frame(height: 6).id(Self.topID)
                    ForEach(transcript.sentences) { sentence in
                        TranscriptSentenceRow(
                            sentence: sentence,
                            tone: tone(of: sentence, in: transcript)
                        ) { store.jump(to: sentence.id) }
                        .id(sentence.id)
                    }
                    TranscriptFooter(transcript: transcript)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .onAppear { scrollToLit(proxy, animated: false) }
            .onChange(of: store.currentIndex) { _ in
                guard scroll.followsPlayback() else { return }
                scrollToLit(proxy, animated: true)
            }
            .onChange(of: transcript.readID) { _ in
                // A new read: start at the top, even mid-hold. A restarted
                // read keeps its place (the lit sentence follows shortly).
                if transcript.sentences.isEmpty { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    private static let topID = -1

    private func scrollToLit(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let index = store.currentIndex else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: Self.litAnchor) }
        } else {
            proxy.scrollTo(index, anchor: Self.litAnchor)
        }
    }

    /// A little above centre: what's coming next gets more room than what
    /// has been read.
    private static let litAnchor = UnitPoint(x: 0.5, y: 0.38)

    private func tone(of sentence: TranscriptSentence, in transcript: Transcript) -> TranscriptSentenceRow.Tone {
        if transcript.ending != nil { return .rest }
        guard let current = store.currentIndex else {
            return sentence.anchor == nil ? .read : .upcoming
        }
        if sentence.id == current { return .lit }
        return sentence.id < current ? .read : .upcoming
    }

    // MARK: - empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DashboardDesign.tertiary)
            Text("Nothing read yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DashboardDesign.title)
            Text("Start a read and its text appears here, one sentence at a time. Click a sentence to play from it.")
                .font(.system(size: 12))
                .foregroundStyle(DashboardDesign.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - rows

struct TranscriptSentenceRow: View {
    enum Tone: Equatable {
        /// Being read now.
        case lit
        /// Already read (or carried over from before a restart).
        case read
        /// Still to come.
        case upcoming
        /// The read is over: no light, all even.
        case rest
    }

    let sentence: TranscriptSentence
    let tone: Tone
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(sentence.text)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play from this sentence")
        .accessibilityAddTraits(tone == .lit ? .isSelected : [])
        .accessibilityHint("Plays from this sentence")
    }

    private var foreground: Color {
        switch tone {
        case .lit: return DashboardDesign.accent
        case .read: return Color.white.opacity(hovering ? 0.6 : 0.36)
        case .upcoming: return Color.white.opacity(hovering ? 0.8 : 0.58)
        case .rest: return Color.white.opacity(hovering ? 0.9 : 0.72)
        }
    }

    private var background: Color {
        if tone == .lit { return DashboardDesign.accent.opacity(0.14) }
        return Color.white.opacity(hovering ? 0.05 : 0)
    }
}

/// Below the last sentence: what's still coming, or how the read ended.
struct TranscriptFooter: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if transcript.ending == nil, !transcript.synthesisDone {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(transcript.sentences.isEmpty ? "Preparing\u{2026}" : "Preparing the rest\u{2026}")
                }
            } else if let ending = transcript.ending {
                HStack(spacing: 6) {
                    Image(systemName: ending == .finished ? "checkmark" : "stop.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(ending == .finished ? "Finished" : "Stopped")
                }
            }
            if transcript.isPartial {
                Text("Myna's voice service sent only the first 200 characters of some parts, so text is "
                    + "missing here. It still played in full. Updating Myna fixes this.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(DashboardDesign.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }
}

struct TranscriptStatusChip: View {
    enum Status: Equatable {
        case preparing, playing, paused, finished, stopped

        var label: String {
            switch self {
            case .preparing: return "Preparing"
            case .playing: return "Reading"
            case .paused: return "Paused"
            case .finished: return "Finished"
            case .stopped: return "Stopped"
            }
        }
    }

    let status: Status

    var body: some View {
        Text(status.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(status == .playing ? DashboardDesign.accent : DashboardDesign.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(status == .playing ? DashboardDesign.accent.opacity(0.16) : Color.white.opacity(0.06))
            )
    }
}
