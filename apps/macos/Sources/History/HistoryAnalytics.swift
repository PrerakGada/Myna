// HistoryAnalytics.swift — pure rollups over [ReadEvent].
//
// Deliberately free of SwiftUI, AppKit and any singleton: everything here
// is a static function from events + a clock to a value type, so the
// numbers the Overview pane shows are unit-testable without launching an
// app or faking a store. The pane renders this and nothing else.
//
// All bucketing is done in the supplied Calendar (the user's current one
// by default) so "today" means today where the user is, and a week
// starts on their locale's first weekday.
import Foundation

/// Time window the Dashboard is showing.
public enum HistoryRange: String, CaseIterable, Sendable, Identifiable {
    case week
    case month
    case quarter
    case year
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: return "7 days"
        case .month: return "30 days"
        case .quarter: return "90 days"
        case .year: return "1 year"
        case .all: return "All time"
        }
    }

    /// Number of day-buckets the charts should draw. nil for `.all`,
    /// which spans from the first event.
    public var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .year: return 365
        case .all: return nil
        }
    }
}

/// One calendar day of activity. Always dense — days with nothing read
/// are present with zeroes so charts don't silently close gaps.
public struct DayBucket: Sendable, Equatable, Identifiable {
    public let day: Date
    public var reads: Int
    public var words: Int
    public var listenedSeconds: Double

    public var id: Date { day }

    public init(day: Date, reads: Int = 0, words: Int = 0, listenedSeconds: Double = 0) {
        self.day = day
        self.reads = reads
        self.words = words
        self.listenedSeconds = listenedSeconds
    }
}

/// A named slice — a voice, a source, an app. Sorted by `reads`
/// descending by the summarizer.
public struct CountBucket: Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public var reads: Int
    public var listenedSeconds: Double

    public var id: String { key }

    public init(key: String, label: String, reads: Int = 0, listenedSeconds: Double = 0) {
        self.key = key
        self.label = label
        self.reads = reads
        self.listenedSeconds = listenedSeconds
    }
}

/// Reads bucketed by hour of day, 0…23. Always 24 entries.
public struct HourBucket: Sendable, Equatable, Identifiable {
    public let hour: Int
    public var reads: Int
    public var id: Int { hour }

    public init(hour: Int, reads: Int = 0) {
        self.hour = hour
        self.reads = reads
    }
}

/// Everything the Overview pane draws.
public struct AnalyticsSummary: Sendable, Equatable {
    public var totalReads: Int = 0
    public var completedReads: Int = 0
    public var failedReads: Int = 0
    public var totalWords: Int = 0
    public var totalCharacters: Int = 0
    /// Seconds of audio actually heard.
    public var listenedSeconds: Double = 0
    /// Seconds of audio produced (heard or not).
    public var audioSeconds: Double = 0
    /// Mean playback rate across reads that produced audio.
    public var averageSpeed: Double = 1.0
    /// Mean ms to first audio, over reads that reported it.
    public var averageFirstAudioMs: Double?
    /// completed ÷ terminal reads, 0…1.
    public var completionRate: Double = 0
    /// Consecutive days up to and including today with at least one read.
    public var currentStreakDays: Int = 0
    public var longestStreakDays: Int = 0
    /// Estimated seconds of silent reading the listening replaced. An
    /// estimate, labelled as one in the UI.
    public var estimatedReadingSeconds: Double = 0
    public var firstEventDate: Date?
    public var busiestDay: DayBucket?
    public var daily: [DayBucket] = []
    public var byVoice: [CountBucket] = []
    public var bySource: [CountBucket] = []
    public var byApp: [CountBucket] = []
    public var byHour: [HourBucket] = []

    public var isEmpty: Bool { totalReads == 0 }

    /// Mean words per read, 0 when there is nothing.
    public var averageWords: Int {
        guard totalReads > 0 else { return 0 }
        return totalWords / totalReads
    }

    public init() {}
}

public enum HistoryAnalytics {

    /// Filter to the events inside `range`, relative to `now`.
    public static func filter(
        _ events: [ReadEvent],
        range: HistoryRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ReadEvent] {
        guard let days = range.days else { return events }
        let startOfToday = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else {
            return events
        }
        let cutoffMs = Int(cutoff.timeIntervalSince1970 * 1000)
        return events.filter { $0.startedAtMs >= cutoffMs }
    }

    /// The whole Overview, in one pass plus a few sorts.
    public static func summarize(
        _ allEvents: [ReadEvent],
        range: HistoryRange = .month,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> AnalyticsSummary {
        let events = filter(allEvents, range: range, now: now, calendar: calendar)
        var summary = AnalyticsSummary()
        guard !events.isEmpty else {
            summary.daily = denseDays(from: [:], range: range, events: events, now: now, calendar: calendar)
            summary.byHour = (0..<24).map { HourBucket(hour: $0) }
            return summary
        }

        var buckets = Buckets()
        var running = RunningTotals()

        for event in events {
            running.add(event, into: &summary, buckets: &buckets, calendar: calendar)
        }

        running.finish(into: &summary)
        summary.daily = denseDays(from: buckets.dayMap, range: range, events: events, now: now, calendar: calendar)
        // Ties broken toward the more recent day: `max(by:)` keeps the
        // FIRST maximal element and `daily` is oldest-first, so without the
        // date in the comparison a tie silently reported the oldest day.
        summary.busiestDay = summary.daily
            .max { ($0.reads, $0.day) < ($1.reads, $1.day) }
            .flatMap { $0.reads > 0 ? $0 : nil }
        summary.byVoice = buckets.voiceMap.values.sorted(by: rank)
        summary.bySource = buckets.sourceMap.values.sorted(by: rank)
        summary.byApp = buckets.appMap.values.sorted(by: rank)
        summary.byHour = buckets.hours

        // Streaks are computed over the WHOLE history, not the filtered
        // window — a 7-day view showing "streak: 7" when the real streak
        // is 40 days would be a lie by framing.
        let streaks = streakDays(allEvents, now: now, calendar: calendar)
        summary.currentStreakDays = streaks.current
        summary.longestStreakDays = streaks.longest
        return summary
    }

    // MARK: - helpers

    /// The four group-by tables plus the hour histogram, carried together
    /// so the fold below takes an argument list you can read.
    private struct Buckets {
        var dayMap: [Date: DayBucket] = [:]
        var voiceMap: [String: CountBucket] = [:]
        var sourceMap: [String: CountBucket] = [:]
        var appMap: [String: CountBucket] = [:]
        var hours: [HourBucket] = (0..<24).map { HourBucket(hour: $0) }
    }

    /// The per-event fold, split out of `summarize` so that method stays a
    /// readable outline (and inside the body-length limit). Holds only the
    /// counters that need a denominator at the end; everything that is a
    /// plain sum lands directly on the summary.
    private struct RunningTotals {
        var speedSum = 0.0
        var speedCount = 0
        var latencySum = 0.0
        var latencyCount = 0
        var terminalCount = 0
        var earliestMs = Int.max

        mutating func add(
            _ event: ReadEvent,
            into summary: inout AnalyticsSummary,
            buckets: inout Buckets,
            calendar: Calendar
        ) {
            summary.totalReads += 1
            summary.totalWords += event.words
            summary.totalCharacters += event.characters
            summary.listenedSeconds += event.listenedSeconds
            summary.audioSeconds += event.audioSeconds
            summary.estimatedReadingSeconds += event.estimatedSilentReadingSeconds
            earliestMs = min(earliestMs, event.startedAtMs)

            switch event.outcome {
            case .completed:
                summary.completedReads += 1
                terminalCount += 1
            case .failed:
                summary.failedReads += 1
                terminalCount += 1
            case .stopped:
                terminalCount += 1
            case .reading:
                break
            }

            if event.audioSeconds > 0 {
                speedSum += event.speed
                speedCount += 1
            }
            if let ms = event.firstAudioMs {
                latencySum += Double(ms)
                latencyCount += 1
            }

            let day = calendar.startOfDay(for: event.startedAt)
            var bucket = buckets.dayMap[day] ?? DayBucket(day: day)
            bucket.reads += 1
            bucket.words += event.words
            bucket.listenedSeconds += event.listenedSeconds
            buckets.dayMap[day] = bucket

            HistoryAnalytics.accumulate(
                &buckets.voiceMap, key: event.voice, label: event.voice,
                seconds: event.listenedSeconds)
            HistoryAnalytics.accumulate(
                &buckets.sourceMap, key: event.source.rawValue, label: event.source.label,
                seconds: event.listenedSeconds)
            if let appKey = event.appBundleId ?? event.appName {
                HistoryAnalytics.accumulate(
                    &buckets.appMap, key: appKey, label: event.appName ?? appKey,
                    seconds: event.listenedSeconds)
            }

            let hour = calendar.component(.hour, from: event.startedAt)
            if buckets.hours.indices.contains(hour) { buckets.hours[hour].reads += 1 }
        }

        /// Turn the counters into the averages and rates the UI shows.
        func finish(into summary: inout AnalyticsSummary) {
            summary.averageSpeed = speedCount > 0 ? speedSum / Double(speedCount) : 1.0
            summary.averageFirstAudioMs =
                latencyCount > 0 ? latencySum / Double(latencyCount) : nil
            summary.completionRate =
                terminalCount > 0 ? Double(summary.completedReads) / Double(terminalCount) : 0
            summary.firstEventDate =
                earliestMs == Int.max
                ? nil : Date(timeIntervalSince1970: Double(earliestMs) / 1000)
        }
    }

    private static func accumulate(
        _ map: inout [String: CountBucket], key: String, label: String, seconds: Double
    ) {
        var bucket = map[key] ?? CountBucket(key: key, label: label)
        bucket.reads += 1
        bucket.listenedSeconds += seconds
        map[key] = bucket
    }

    /// Reads desc, then listening desc, then label — a total order, so the
    /// chart legend doesn't reshuffle between identical renders.
    private static func rank(_ lhs: CountBucket, _ rhs: CountBucket) -> Bool {
        if lhs.reads != rhs.reads { return lhs.reads > rhs.reads }
        if lhs.listenedSeconds != rhs.listenedSeconds {
            return lhs.listenedSeconds > rhs.listenedSeconds
        }
        return lhs.label < rhs.label
    }

    /// Fill every day in the window, including empty ones, oldest first.
    private static func denseDays(
        from map: [Date: DayBucket],
        range: HistoryRange,
        events: [ReadEvent],
        now: Date,
        calendar: Calendar
    ) -> [DayBucket] {
        let today = calendar.startOfDay(for: now)
        let spanDays: Int
        if let days = range.days {
            spanDays = days
        } else if let earliest = events.map(\.startedAt).min() {
            let start = calendar.startOfDay(for: earliest)
            let diff = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            // Cap an "all time" chart so a two-year history doesn't try to
            // draw 700 bars into 600 points of width.
            spanDays = min(max(diff + 1, 1), 365)
        } else {
            spanDays = 1
        }
        var out: [DayBucket] = []
        out.reserveCapacity(spanDays)
        for offset in stride(from: spanDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            out.append(map[day] ?? DayBucket(day: day))
        }
        return out
    }

    /// Current streak counts back from today; a day with no reads ends it.
    /// Today itself not having a read yet does NOT break the streak — it
    /// is still in progress — so we start counting at yesterday in that case.
    public static func streakDays(
        _ events: [ReadEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (current: Int, longest: Int) {
        guard !events.isEmpty else { return (0, 0) }
        let activeDays = Set(events.map { calendar.startOfDay(for: $0.startedAt) })
        let today = calendar.startOfDay(for: now)

        var current = 0
        var cursor = today
        if !activeDays.contains(today) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
                return (0, 0)
            }
            cursor = yesterday
        }
        while activeDays.contains(cursor) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        var longest = 0
        var run = 0
        var previousDay: Date?
        for day in activeDays.sorted() {
            if let previousDay,
                let expected = calendar.date(byAdding: .day, value: 1, to: previousDay),
                expected == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previousDay = day
        }
        return (current, longest)
    }

    // MARK: - formatting
    //
    // Shared so a duration reads the same in a stat tile, a chart axis and
    // a table row.

    /// "4h 12m" · "12m 30s" · "48s". Compact, never zero-padded.
    public static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 { return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    /// "1,204" · "12.4k" · "1.2M" — thousands separators below 10k, then
    /// abbreviations, so a stat tile never has to shrink its type.
    public static func compactCount(_ value: Int) -> String {
        if value < 10_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        if value < 1_000_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    public static func percentString(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
