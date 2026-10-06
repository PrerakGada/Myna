// APILogCard.swift — the last requests to /v1 and /v2/renders, newest
// first, refreshed every couple of seconds while the pane is on screen.
//
// The daemon keeps these in memory only and never logs input text, just
// its length, so there is nothing to hide here and nothing to clear.
// Fixed-width numeric columns and flexible text columns keep the table
// legible at the Dashboard's minimum width.
import SwiftUI

struct APILogCard: View {
    @ObservedObject var model: APIPaneModel

    private enum Column {
        static let time: CGFloat = 56
        static let client: CGFloat = 84
        static let status: CGFloat = 34
        static let took: CGFloat = 46
        static let chars: CGFloat = 46
        static let audio: CGFloat = 46
        /// The path is the column people scan: it keeps enough room for
        /// `POST /v1/audio/speech` at the minimum window width, and takes
        /// whatever App doesn't need above that.
        static let request: CGFloat = 150
        static let appMin: CGFloat = 70
        static let appMax: CGFloat = 170
    }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    DashSectionTitle("Recent requests")
                    Spacer(minLength: 8)
                    if !model.logRows.isEmpty {
                        Text("Last \(model.logRows.count) · updates every 2 s")
                            .font(DashboardDesign.captionFont.monospacedDigit())
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                }
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.logError, model.logRows.isEmpty {
            Text(error)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.logRows.isEmpty {
            if model.logLoaded {
                DashEmptyState(
                    systemImage: "list.bullet.rectangle",
                    title: "No requests yet",
                    message: "Run one of the Quick start examples, or press Send request under Try it. "
                        + "Each request shows up here within a couple of seconds. Myna records the length of "
                        + "the text, never the text itself."
                )
                .padding(.vertical, -24)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        } else {
            table
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            header
            DashDivider()
            ForEach(model.logRows) { row in
                rowView(row)
                if row.id != model.logRows.last?.id { DashDivider() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            headerText("Time").frame(width: Column.time, alignment: .leading)
            headerText("Client").frame(width: Column.client, alignment: .leading)
            headerText("App").frame(minWidth: Column.appMin, maxWidth: Column.appMax, alignment: .leading)
            headerText("Request").frame(minWidth: Column.request, maxWidth: .infinity, alignment: .leading)
            headerText("Status").frame(width: Column.status, alignment: .trailing)
            headerText("Took").frame(width: Column.took, alignment: .trailing)
            headerText("Chars").frame(width: Column.chars, alignment: .trailing)
            headerText("Audio").frame(width: Column.audio, alignment: .trailing)
        }
        .padding(.bottom, 6)
    }

    private func headerText(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardDesign.tertiary)
            .lineLimit(1)
    }

    private func rowView(_ row: APILogRow) -> some View {
        HStack(spacing: 8) {
            cell(row.time, mono: true).frame(width: Column.time, alignment: .leading)
            cell(row.client, color: row.isLocal ? DashboardDesign.secondary : DashboardDesign.warning)
                .frame(width: Column.client, alignment: .leading)
                .help(row.isLocal ? "This Mac" : "Another device on your network")
            cell(row.agent).frame(minWidth: Column.appMin, maxWidth: Column.appMax, alignment: .leading)
                .help(row.agent)
            HStack(spacing: 4) {
                Text(row.method)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(DashboardDesign.tertiary)
                cell(row.path, mono: true, color: DashboardDesign.body, truncation: .middle)
            }
            .frame(minWidth: Column.request, maxWidth: .infinity, alignment: .leading)
            .help("\(row.method) \(row.path)")
            cell(row.status, mono: true, color: statusColor(row.tone))
                .frame(width: Column.status, alignment: .trailing)
            cell(row.duration, mono: true).frame(width: Column.took, alignment: .trailing)
            cell(row.chars, mono: true).frame(width: Column.chars, alignment: .trailing)
            cell(row.audio, mono: true).frame(width: Column.audio, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func cell(
        _ value: String,
        mono: Bool = false,
        color: Color = DashboardDesign.secondary,
        truncation: Text.TruncationMode = .tail
    ) -> some View {
        Text(value)
            .font(mono ? .system(size: 11, design: .monospaced) : DashboardDesign.captionFont)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(truncation)
    }

    private func statusColor(_ tone: APILogRow.Tone) -> Color {
        switch tone {
        case .success: return DashboardDesign.positive
        case .clientError: return DashboardDesign.warning
        case .serverError: return DashboardDesign.negative
        }
    }
}
