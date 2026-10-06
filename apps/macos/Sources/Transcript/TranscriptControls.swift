// TranscriptControls.swift — the panel's transport, and the buttons that
// open the panel from the pill and the Dashboard's now-playing strip.
//
// The two open buttons are views of their own so PillView and DashboardView
// (both shared, and PillView already over the length limit) each gain one
// line. Both hide when the Reading pane has the transcript off.
import SwiftUI

/// Previous sentence · play/pause · next sentence · stop, and where we are.
struct TranscriptTransport: View {
    @ObservedObject var store: TranscriptStore

    var body: some View {
        HStack(spacing: 10) {
            TranscriptTransportButton(systemImage: "backward.fill", help: "Previous sentence") {
                store.previousSentence()
            }
            .disabled(!canStep)
            playPauseButton
            TranscriptTransportButton(systemImage: "forward.fill", help: "Next sentence") {
                store.nextSentence()
            }
            .disabled(!canStepForward)
            TranscriptTransportButton(systemImage: "stop.fill", help: "Stop, and clear the queue") {
                store.stop()
            }
            .disabled(store.playback == .idle)
            Spacer(minLength: 8)
            Text(progressLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DashboardDesign.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sentenceCount: Int { store.transcript?.sentences.count ?? 0 }
    private var isOver: Bool { store.transcript?.ending != nil }

    private var canStep: Bool {
        sentenceCount > 0 && (store.currentIndex != nil || isOver)
    }

    private var canStepForward: Bool {
        guard canStep else { return false }
        // After the end, Forward has nowhere to go but the last sentence,
        // which Back already covers.
        guard let current = store.currentIndex, !isOver else { return false }
        return current + 1 < sentenceCount
    }

    private var playPauseButton: some View {
        let playing = store.playback == .playing
        let replay = isOver && sentenceCount > 0
        let help = playing ? "Pause" : (replay ? "Play again from the start" : "Resume")
        return Button { store.togglePlayPause() } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DashboardDesign.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .disabled(!(playing || store.playback == .paused || replay))
    }

    private var progressLabel: String {
        guard sentenceCount > 0 else { return "" }
        if isOver || store.currentIndex == nil {
            return sentenceCount == 1 ? "1 sentence" : "\(sentenceCount) sentences"
        }
        return "Sentence \((store.currentIndex ?? 0) + 1) of \(sentenceCount)"
    }
}

struct TranscriptTransportButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? DashboardDesign.body : DashboardDesign.tertiary.opacity(0.6))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering && isEnabled ? 0.10 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - open buttons

/// In the pill's transport row.
struct TranscriptPillButton: View {
    @AppStorage(TranscriptVisibility.defaultsKey)
    private var visibility: TranscriptVisibility = TranscriptVisibility.defaultValue

    var body: some View {
        if visibility != .off {
            Button { TranscriptPanelController.shared.toggle() } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PillIconButtonStyle())
            .help("Show or hide the transcript")
            .accessibilityLabel("Transcript")
            // Swallow the pill's tap-to-pin, like the other transport buttons.
            .simultaneousGesture(TapGesture().onEnded {})
        }
    }
}

/// At the end of the Dashboard now-playing strip's status line, styled like
/// the strip's transport buttons. It's on the status line rather than in the
/// transport row so the last read's text can be opened after it ends; it
/// pushes itself to the trailing edge.
struct TranscriptStripButton: View {
    @AppStorage(TranscriptVisibility.defaultsKey)
    private var visibility: TranscriptVisibility = TranscriptVisibility.defaultValue
    @ObservedObject var store: TranscriptStore = .shared
    @State private var hovering = false

    var body: some View {
        if visibility != .off, store.transcript != nil {
            Spacer(minLength: 4)
            Button { TranscriptPanelController.shared.toggle() } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? DashboardDesign.title : DashboardDesign.secondary)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(hovering ? 0.09 : 0.04))
                    )
            }
            .buttonStyle(.plain)
            .help("Show or hide the transcript")
            .accessibilityLabel("Transcript")
            .onHover { hovering = $0 }
        }
    }
}
