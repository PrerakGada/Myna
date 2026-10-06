// SummariesCard.swift — the Reading pane's Summaries section: which model
// writes a summary, in what style, whether each model is ready right now,
// and a Try button that shows a summary without reading it aloud.
//
// Its own file so the Reading pane (ControlPanes.swift) gains one line. The
// two pickers bind to the defaults keys SummaryService reads on every
// summary, so a change applies to the very next one.
import SwiftUI

struct SummariesCard: View {
    @AppStorage(SummaryPreferences.backendKey)
    private var backend: SummaryBackendChoice = SummaryPreferences.defaultBackend
    @AppStorage(SummaryPreferences.styleKey)
    private var style: SummaryStyle = SummaryPreferences.defaultStyle
    @ObservedObject private var service = SummaryService.shared
    @State private var trial: SummaryTrial?
    @State private var trying = false

    private var route: SummaryRoute {
        SummaryPlanner.route(choice: backend, apple: service.appleStatus, ollama: service.ollamaStatus)
    }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Summaries")
                    .padding(.bottom, 4)
                Text(Self.intro)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                DashRow("Summarize with", help: Self.backendHelp) {
                    Picker("", selection: $backend) {
                        ForEach(SummaryBackendChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                DashDivider()
                DashRow("Style", help: style.help) {
                    Picker("", selection: $style) {
                        ForEach(SummaryStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                DashDivider()
                statusRows
                DashDivider()
                tryRow
                if let trial { TrialResult(trial: trial) }
            }
        }
        .onAppear {
            service.prewarm()
            Task { await service.refreshStatus() }
        }
    }

    // MARK: - status

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusLine(text: service.appleStatus.statusLine, tint: appleTint)
            StatusLine(text: service.ollamaStatus.statusLine, tint: ollamaTint)
            Text(routeLine)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.vertical, 9)
    }

    private var routeLine: String {
        switch route {
        case .apple:
            return "The next summary is written on this Mac by Apple Intelligence."
                + (backend == .automatic ? " If it declines a text, Ollama tries instead." : "")
        case .ollama:
            return "The next summary is written by Ollama, through Myna's voice service."
        case .unavailable(let notice):
            return "No summary can be written right now. " + notice.hint
        }
    }

    private var appleTint: Color {
        switch service.appleStatus {
        case .ready: return DashboardDesign.positive
        case .downloading: return DashboardDesign.warning
        case .notEnabled: return DashboardDesign.warning
        default: return DashboardDesign.tertiary
        }
    }

    private var ollamaTint: Color {
        switch service.ollamaStatus {
        case .ready: return DashboardDesign.positive
        case .checking, .unknown: return DashboardDesign.tertiary
        case .modelMissing, .notRunning: return DashboardDesign.warning
        case .notInstalled: return DashboardDesign.tertiary
        }
    }

    // MARK: - Try

    private var tryRow: some View {
        DashRow("Try it", help: Self.tryHelp) {
            HStack(spacing: 8) {
                if trying { ProgressView().controlSize(.small) }
                Button(trying ? "Summarizing…" : "Try") {
                    trying = true
                    trial = nil
                    Task {
                        trial = await service.trySample(style: style)
                        trying = false
                    }
                }
                .disabled(trying)
            }
        }
    }

    // Kept as constants: the CI compiler refuses to type-check chained
    // string concatenation inside a ViewBuilder (see GesturesPane).
    static let intro =
        "For the summary shortcut, the menu's Summarize and Services ▸ Summarize with Myna. "
        + "Myna writes the summary first, then reads it; History keeps the original text."
    static let backendHelp =
        "Automatic uses Apple Intelligence on this Mac when it's ready, and Ollama when it isn't "
        + "or when Apple's model declines a text. The other two use only the model named."
    static let tryHelp =
        "Summarizes a short sample paragraph about an office move in the chosen style and shows the "
        + "result here. Nothing is read aloud."
}

/// A coloured dot and one line of status.
private struct StatusLine: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text)
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Try button's answer: the summary text and who wrote it how fast, or
/// the notice a real summary read would have shown.
private struct TrialResult: View {
    let trial: SummaryTrial

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = trial.notice {
                Text(notice.title)
                    .font(DashboardDesign.bodyFont.weight(.medium))
                    .foregroundStyle(DashboardDesign.warning)
                Text(notice.hint)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let text = trial.text {
                Text(text)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(byline)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
            } else {
                Text("Stopped before it finished.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.cardRaised)
        )
        .padding(.bottom, 7)
    }

    private var byline: String {
        var parts = [trial.backend == .apple ? "Apple Intelligence" : "Ollama"]
        if let timing = trial.timing {
            parts.append(String(format: "%.1f s", timing.totalSeconds))
            if let first = timing.firstTokenSeconds {
                parts.append(String(format: "first words after %.1f s", first))
            }
        }
        return parts.joined(separator: " · ")
    }
}
