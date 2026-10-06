// OverviewPane.swift — the analytics screen.
//
// Every number here is computed by HistoryAnalytics from the real
// ReadEvent log; nothing is estimated except the explicitly-labelled
// "reading it yourself" comparison. If the log is empty the pane says so
// rather than drawing a chart of zeroes.
import Charts
import SwiftUI

struct OverviewPane: View {
    @ObservedObject var history: HistoryStore
    let onOpenHistory: () -> Void

    @State private var range: HistoryRange = .month
    @State private var activityMetric: ActivityMetric = .reads

    enum ActivityMetric: String, CaseIterable, Identifiable {
        case reads
        case minutes
        var id: String { rawValue }
        var label: String { self == .reads ? "Reads" : "Listening" }
    }

    private var summary: AnalyticsSummary {
        HistoryAnalytics.summarize(history.events, range: range)
    }

    var body: some View {
        let stats = summary
        PaneScaffold(
            title: DashboardPane.overview.title,
            subtitle: DashboardPane.overview.subtitle
        ) {
            Picker("", selection: $range) {
                ForEach(HistoryRange.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
        } content: {
            if history.events.isEmpty {
                DashCard {
                    DashEmptyState(
                        systemImage: "chart.bar.xaxis",
                        title: "Nothing read yet",
                        message: "Select some text anywhere and press the speak shortcut. "
                            + "Every read lands here — what it was, how long you listened, "
                            + "and which voice said it."
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                    statGrid(stats)
                    activityCard(stats)
                    HStack(alignment: .top, spacing: DashboardDesign.gridSpacing) {
                        breakdownCard(
                            title: "Where it came from",
                            buckets: stats.bySource,
                            emptyMessage: "No sources recorded yet."
                        )
                        breakdownCard(
                            title: "Voices used",
                            buckets: stats.byVoice,
                            emptyMessage: "No voices recorded yet."
                        )
                    }
                    HStack(alignment: .top, spacing: DashboardDesign.gridSpacing) {
                        hourCard(stats)
                        appsCard(stats)
                    }
                    timeSavedCard(stats)
                    LatestReadsCard(
                        events: Array(history.events.prefix(5)),
                        onSeeAll: onOpenHistory
                    )
                }
            }
        }
    }

    // MARK: - stat tiles

    @ViewBuilder
    private func statGrid(_ stats: AnalyticsSummary) -> some View {
        let columns = [
            GridItem(.adaptive(minimum: 168), spacing: DashboardDesign.gridSpacing)
        ]
        LazyVGrid(columns: columns, spacing: DashboardDesign.gridSpacing) {
            StatTile(
                label: "Reads",
                value: HistoryAnalytics.compactCount(stats.totalReads),
                footnote: "\(stats.completedReads) finished",
                systemImage: "text.badge.checkmark"
            )
            StatTile(
                label: "Listening time",
                value: HistoryAnalytics.durationString(stats.listenedSeconds),
                footnote: "of \(HistoryAnalytics.durationString(stats.audioSeconds)) produced",
                systemImage: "headphones",
                tint: DashboardDesign.positive
            )
            StatTile(
                label: "Words heard",
                value: HistoryAnalytics.compactCount(stats.totalWords),
                footnote: "\(HistoryAnalytics.compactCount(stats.averageWords)) per read",
                systemImage: "textformat.abc",
                tint: DashboardDesign.info
            )
            StatTile(
                label: "Finished",
                value: HistoryAnalytics.percentString(stats.completionRate),
                footnote: stats.failedReads > 0
                    ? "\(stats.failedReads) failed" : "no failures",
                systemImage: "checkmark.circle",
                tint: stats.failedReads > 0 ? DashboardDesign.warning : DashboardDesign.positive
            )
            StatTile(
                label: "Streak",
                value: "\(stats.currentStreakDays)d",
                footnote: "best \(stats.longestStreakDays)d",
                systemImage: "flame",
                tint: DashboardDesign.warning
            )
            StatTile(
                label: "Time to first word",
                value: stats.averageFirstAudioMs.map { "\(Int($0.rounded()))ms" } ?? "—",
                footnote: "average across reads",
                systemImage: "bolt",
                tint: latencyTint(stats.averageFirstAudioMs)
            )
        }
    }

    /// Latency is the one number with a health reading attached: under a
    /// second feels instant, over three seconds is the engine struggling.
    private func latencyTint(_ ms: Double?) -> Color {
        guard let ms else { return DashboardDesign.tertiary }
        if ms < 1_000 { return DashboardDesign.positive }
        if ms < 3_000 { return DashboardDesign.warning }
        return DashboardDesign.negative
    }

    // MARK: - activity

    @ViewBuilder
    private func activityCard(_ stats: AnalyticsSummary) -> some View {
        DashCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    DashSectionTitle("Activity")
                    Spacer()
                    Picker("", selection: $activityMetric) {
                        ForEach(ActivityMetric.allCases) { metric in
                            Text(metric.label).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                Chart(stats.daily) { bucket in
                    BarMark(
                        x: .value("Day", bucket.day, unit: .day),
                        y: .value(
                            activityMetric.label,
                            activityMetric == .reads
                                ? Double(bucket.reads)
                                : bucket.listenedSeconds / 60)
                    )
                    .foregroundStyle(DashboardDesign.accent.gradient)
                    .cornerRadius(2)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(DashboardDesign.separator)
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(
                                    activityMetric == .reads
                                        ? "\(Int(number))"
                                        : "\(Int(number))m"
                                )
                                .font(DashboardDesign.captionFont)
                                .foregroundStyle(DashboardDesign.tertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                }
                .frame(height: 180)
                if let busiest = stats.busiestDay {
                    Text(
                        "Busiest day: \(busiest.day.formatted(date: .abbreviated, time: .omitted)) "
                            + "— \(busiest.reads) read\(busiest.reads == 1 ? "" : "s")."
                    )
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                }
            }
        }
    }

    // MARK: - breakdowns

    @ViewBuilder
    private func breakdownCard(
        title: String, buckets: [CountBucket], emptyMessage: String
    ) -> some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                DashSectionTitle(title)
                if buckets.isEmpty {
                    Text(emptyMessage)
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.secondary)
                } else {
                    let total = max(1, buckets.reduce(0) { $0 + $1.reads })
                    VStack(spacing: 9) {
                        ForEach(Array(buckets.prefix(6).enumerated()), id: \.element.id) { index, bucket in
                            ProportionRow(
                                label: bucket.label,
                                detail: "\(bucket.reads)",
                                fraction: Double(bucket.reads) / Double(total),
                                tint: DashboardDesign.seriesColor(index)
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appsCard(_ stats: AnalyticsSummary) -> some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                DashSectionTitle("Apps you read from")
                if stats.byApp.isEmpty {
                    Text("Myna records which app was frontmost when you triggered a read. Nothing recorded yet.")
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let total = max(1, stats.byApp.reduce(0) { $0 + $1.reads })
                    VStack(spacing: 9) {
                        ForEach(Array(stats.byApp.prefix(6).enumerated()), id: \.element.id) { index, bucket in
                            ProportionRow(
                                label: bucket.label,
                                detail: HistoryAnalytics.durationString(bucket.listenedSeconds),
                                fraction: Double(bucket.reads) / Double(total),
                                tint: DashboardDesign.seriesColor(index + 2)
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func hourCard(_ stats: AnalyticsSummary) -> some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                DashSectionTitle("When you listen")
                Chart(stats.byHour) { bucket in
                    BarMark(
                        x: .value("Hour", bucket.hour),
                        y: .value("Reads", bucket.reads)
                    )
                    .foregroundStyle(DashboardDesign.seriesColor(1).gradient)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(Self.hourLabel(hour))
                                    .font(DashboardDesign.captionFont)
                                    .foregroundStyle(DashboardDesign.tertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(DashboardDesign.separator)
                        AxisValueLabel()
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                }
                .frame(height: 140)
            }
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case let h where h < 12: return "\(h)a"
        default: return "\(hour - 12)p"
        }
    }

    // MARK: - time saved

    @ViewBuilder
    private func timeSavedCard(_ stats: AnalyticsSummary) -> some View {
        DashCard {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "hourglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(DashboardDesign.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "You heard \(HistoryAnalytics.compactCount(stats.totalWords)) words "
                            + "in \(HistoryAnalytics.durationString(stats.listenedSeconds))."
                    )
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DashboardDesign.title)
                    Text(
                        "Reading that yourself would take about "
                            + "\(HistoryAnalytics.durationString(stats.estimatedReadingSeconds)) "
                            + "at 238 words a minute — the average silent reading speed for adult "
                            + "English prose. That is an estimate, not a measurement: it assumes you "
                            + "would have read every word."
                    )
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Label + proportional bar + value. The Dashboard's one repeated
/// breakdown primitive — used for sources, voices and apps so the three
/// cards read as the same kind of information.
struct ProportionRow: View {
    let label: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(detail)")
    }
}

/// The five most recent reads, with a way through to the full History
/// pane. Its own view rather than a method on OverviewPane so the pane
/// stays an outline of cards rather than a 400-line type.
private struct LatestReadsCard: View {
    let events: [ReadEvent]
    let onSeeAll: () -> Void

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    DashSectionTitle("Latest")
                    Spacer()
                    Button("See all", action: onSeeAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DashboardDesign.accent)
                }
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        row(event)
                        if event.id != events.last?.id { DashDivider() }
                    }
                }
            }
        }
    }

    private func row(_ event: ReadEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.source.systemImage)
                .font(.system(size: 11))
                .foregroundStyle(DashboardDesign.tertiary)
                .frame(width: 16)
            Text(event.truncatedTitle(maxLength: 70))
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.body)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(event.voice)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
            Text(event.startedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}
