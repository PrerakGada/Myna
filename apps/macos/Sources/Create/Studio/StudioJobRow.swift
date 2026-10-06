// StudioJobRow.swift — one render job in the library.
//
// A row's shape follows its state: a progress bar and Cancel while it
// renders; play, share and a menu of file actions once it's done (and the
// whole row drags out to Finder as the file); the reason and Retry when it
// failed. Clicking a row opens its details and, for a book, its chapters.
import SwiftUI

struct StudioRowActions {
    let play: () -> Void
    let playChapter: (Int) -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let delete: () -> Void
    let reveal: () -> Void
    let saveCopy: () -> Void
    let share: (NSView?) -> Void
}

struct StudioJobRow: View {
    let job: RenderJob
    let presentation: StudioJobPresentation
    let isExpanded: Bool
    let isCurrent: Bool
    let isPlaying: Bool
    let isBusy: Bool
    let onToggleExpanded: () -> Void
    let actions: StudioRowActions

    @State private var isHovering = false
    @State private var shareAnchor = StudioViewAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                statusIcon
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(job.title)
                            .font(DashboardDesign.bodyFont)
                            .foregroundStyle(DashboardDesign.title)
                            .lineLimit(1)
                        if !presentation.badge.isEmpty {
                            DashBadge(presentation.badge, tint: tint)
                        }
                    }
                    Text(presentation.detail)
                        .font(DashboardDesign.captionFont.monospacedDigit())
                        .foregroundStyle(DashboardDesign.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let failure = presentation.failure {
                        Text(failure)
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.negative)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                    }
                    progressBar
                }
                Spacer(minLength: 8)
                trailingControls
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpanded)

            if isExpanded {
                StudioJobDetails(job: job, onPlayChapter: actions.playChapter)
                    .padding(.leading, 43)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(rowFill)
        .onHover { isHovering = $0 }
        .modifier(DragOutIfDone(job: job, enabled: presentation.phase == .done))
        .accessibilityElement(children: .contain)
    }

    private var tint: Color {
        switch presentation.tint {
        case .accent: return DashboardDesign.accent
        case .positive: return DashboardDesign.positive
        case .warning: return DashboardDesign.warning
        case .negative: return DashboardDesign.negative
        case .neutral: return DashboardDesign.secondary
        }
    }

    private var rowFill: Color {
        if isExpanded || isCurrent { return Color.white.opacity(0.06) }
        if isHovering { return Color.white.opacity(0.035) }
        return .clear
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.phase {
        case .queued:
            Image(systemName: "clock").foregroundStyle(DashboardDesign.secondary)
        case .rendering, .encoding:
            Image(systemName: "waveform").foregroundStyle(DashboardDesign.accent)
        case .done:
            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "waveform")
                .foregroundStyle(isCurrent ? DashboardDesign.accent : DashboardDesign.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(DashboardDesign.negative)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(DashboardDesign.tertiary)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if presentation.showsIndeterminateProgress {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(DashboardDesign.accent)
        } else if let progress = presentation.progress {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(DashboardDesign.accent)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int(progress * 100)) percent")
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 10) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            switch presentation.phase {
            case .queued, .rendering, .encoding:
                Button("Cancel", action: actions.cancel)
                    .controlSize(.small)
                    .disabled(isBusy)
            case .done:
                iconButton(isPlaying ? "pause.circle" : "play.circle", help: isPlaying ? "Pause" : "Play here",
                           action: actions.play)
                    .disabled(!presentation.canPlay)
                iconButton("square.and.arrow.up", help: "Share (AirDrop, Mail, Messages…)") {
                    actions.share(shareAnchor.view)
                }
                .background(StudioAnchorView(anchor: shareAnchor))
                fileMenu
            case .failed, .cancelled:
                Button("Retry", action: actions.retry)
                    .controlSize(.small)
                    .disabled(!presentation.canRetry || isBusy)
                    .help(presentation.canRetry
                        ? "Render it again with the same text and settings"
                        : "Myna doesn't have this one's text any more. Start it again from Studio.")
                iconButton("trash", help: "Delete", action: actions.delete)
                    .disabled(isBusy)
            }
        }
    }

    private var fileMenu: some View {
        Menu {
            Button("Show in Finder", action: actions.reveal)
            Button("Save a Copy…", action: actions.saveCopy)
            Button("Share…") { actions.share(shareAnchor.view) }
            Divider()
            Button("Delete…", role: .destructive, action: actions.delete)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isHovering || isCurrent ? DashboardDesign.body : DashboardDesign.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Finished files drag out as a title-named copy.
private struct DragOutIfDone: ViewModifier {
    let job: RenderJob
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { StudioFileActions.dragProvider(for: job) }
        } else {
            content
        }
    }
}

/// The expanded part of a row: chapters to jump to, and the facts.
private struct StudioJobDetails: View {
    let job: RenderJob
    let onPlayChapter: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.status == .done, let chapters = job.chapters, chapters.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    DashSectionTitle("Chapters")
                        .padding(.bottom, 4)
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        ChapterLine(index: index, chapter: chapter) { onPlayChapter(index) }
                    }
                }
            }
            if let preview = job.preview, !preview.isEmpty {
                // The daemon's preview already ends in "…" when it was cut.
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardDesign.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(facts)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var facts: String {
        var parts = ["Engine: \(job.engine)", "voice: \(job.voice)", "speed: \(StudioFormat.speed(job.speed))"]
        if job.words > 0 { parts.append("\(HistoryAnalytics.compactCount(job.words)) words") }
        parts.append("from \(job.source)")
        if let path = job.filePath { parts.append((path as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }
}

private struct ChapterLine: View {
    let index: Int
    let chapter: RenderChapter
    let onPlay: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .frame(width: 22, alignment: .trailing)
                    .foregroundStyle(DashboardDesign.tertiary)
                Text(chapter.title)
                    .foregroundStyle(hovering ? DashboardDesign.title : DashboardDesign.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(StudioFormat.clock(chapter.startS))
                    .foregroundStyle(DashboardDesign.tertiary)
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(hovering ? DashboardDesign.accent : .clear)
            }
            .font(DashboardDesign.captionFont.monospacedDigit())
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play from here")
    }
}
