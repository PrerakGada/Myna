// HistoryAnalyticsTests.swift — the numbers the Overview pane prints.
//
// Everything here is deterministic: a fixed `now`, a fixed calendar in UTC,
// and hand-built events. A chart that quietly miscounts is worse than no
// chart, so each rollup is asserted against a value computed by hand.
import XCTest

@testable import Myna

final class HistoryAnalyticsTests: XCTestCase {

    /// Fixed clock: 2026-09-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_789_560_000)

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func event(
        daysAgo: Int = 0,
        hour: Int = 12,
        outcome: ReadOutcome = .completed,
        voice: String = "af_heart",
        source: ReadSource = .selection,
        app: String? = nil,
        words: Int = 100,
        listened: Double = 60,
        audio: Double = 60,
        speed: Double = 1.0,
        firstAudioMs: Int? = nil
    ) -> ReadEvent {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        return ReadEvent(
            startedAtMs: Int(start.timeIntervalSince1970 * 1000),
            title: "Read",
            source: source,
            voice: voice,
            speed: speed,
            characters: words * 5,
            words: words,
            firstAudioMs: firstAudioMs,
            audioSeconds: audio,
            listenedSeconds: listened,
            appBundleId: app,
            appName: app,
            outcome: outcome
        )
    }

    private func summarize(_ events: [ReadEvent], range: HistoryRange = .month) -> AnalyticsSummary {
        HistoryAnalytics.summarize(events, range: range, now: now, calendar: calendar)
    }

    // MARK: - totals

    func testEmptyHistoryProducesEmptySummaryWithDenseAxes() {
        let summary = summarize([])
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.totalReads, 0)
        // Charts still need their axes, or an empty state draws as a glitch.
        XCTAssertEqual(summary.daily.count, 30)
        XCTAssertEqual(summary.byHour.count, 24)
    }

    func testTotalsSumAcrossEvents() {
        let summary = summarize([
            event(words: 100, listened: 60, audio: 60),
            event(daysAgo: 1, words: 250, listened: 30, audio: 120),
        ])
        XCTAssertEqual(summary.totalReads, 2)
        XCTAssertEqual(summary.totalWords, 350)
        XCTAssertEqual(summary.totalCharacters, 1_750)
        XCTAssertEqual(summary.listenedSeconds, 90)
        XCTAssertEqual(summary.audioSeconds, 180)
        XCTAssertEqual(summary.averageWords, 175)
    }

    func testCompletionRateCountsOnlyTerminalReads() {
        let summary = summarize([
            event(outcome: .completed),
            event(outcome: .completed),
            event(outcome: .stopped),
            event(outcome: .failed),
            // Still playing — must not drag the rate down before it ends.
            event(outcome: .reading),
        ])
        XCTAssertEqual(summary.completedReads, 2)
        XCTAssertEqual(summary.failedReads, 1)
        XCTAssertEqual(summary.completionRate, 0.5, accuracy: 0.0001)
    }

    /// Speed is averaged over reads that produced audio; a failure that
    /// never synthesized anything would otherwise pull the average toward
    /// a speed nobody actually heard.
    func testAverageSpeedIgnoresReadsWithNoAudio() {
        let summary = summarize([
            event(audio: 60, speed: 1.0),
            event(audio: 60, speed: 2.0),
            event(outcome: .failed, listened: 0, audio: 0, speed: 0.5),
        ])
        XCTAssertEqual(summary.averageSpeed, 1.5, accuracy: 0.0001)
    }

    func testAverageFirstAudioIsNilWhenNothingReportedIt() {
        XCTAssertNil(summarize([event()]).averageFirstAudioMs)
        let summary = summarize([
            event(firstAudioMs: 800),
            event(firstAudioMs: 1_200),
            event(firstAudioMs: nil),
        ])
        XCTAssertEqual(try XCTUnwrap(summary.averageFirstAudioMs), 1_000, accuracy: 0.0001)
    }

    // MARK: - windowing

    func testRangeFiltersToWindow() {
        let events = [event(daysAgo: 0), event(daysAgo: 3), event(daysAgo: 20)]
        XCTAssertEqual(summarize(events, range: .week).totalReads, 2)
        XCTAssertEqual(summarize(events, range: .month).totalReads, 3)
        XCTAssertEqual(summarize(events, range: .all).totalReads, 3)
    }

    /// A 7-day window includes today plus the six days before it — an
    /// off-by-one here silently drops or double-counts a day's reads.
    func testWeekWindowIncludesTodayAndSixPriorDays() {
        let events = [event(daysAgo: 6), event(daysAgo: 7)]
        let summary = summarize(events, range: .week)
        XCTAssertEqual(summary.totalReads, 1)
        XCTAssertEqual(summary.daily.count, 7)
    }

    func testDailyBucketsAreDenseAndOldestFirst() {
        let summary = summarize([event(daysAgo: 2)], range: .week)
        XCTAssertEqual(summary.daily.count, 7)
        XCTAssertEqual(summary.daily.map(\.reads), [0, 0, 0, 0, 1, 0, 0])
        let days = summary.daily.map(\.day)
        XCTAssertEqual(days, days.sorted(), "charts read left-to-right in time")
    }

    func testBusiestDayIsNilWhenNothingWasRead() {
        XCTAssertNil(summarize([]).busiestDay)
    }

    func testBusiestDayPicksTheHighestCount() throws {
        let summary = summarize([
            event(daysAgo: 1), event(daysAgo: 1), event(daysAgo: 1),
            event(daysAgo: 2),
        ])
        XCTAssertEqual(try XCTUnwrap(summary.busiestDay).reads, 3)
    }

    /// Two days with the same count is common; reporting the older one
    /// reads as stale. The more recent day wins.
    func testBusiestDayBreaksTiesTowardTheMoreRecentDay() throws {
        let summary = summarize([
            event(daysAgo: 8), event(daysAgo: 8),
            event(daysAgo: 2), event(daysAgo: 2),
        ])
        let busiest = try XCTUnwrap(summary.busiestDay)
        XCTAssertEqual(busiest.reads, 2)
        let expected = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -2, to: now)!)
        XCTAssertEqual(busiest.day, expected)
    }

    // MARK: - breakdowns

    func testBreakdownsAreRankedByReadsDescending() {
        let summary = summarize([
            event(voice: "af_heart"), event(voice: "af_heart"), event(voice: "af_heart"),
            event(voice: "am_michael"), event(voice: "am_michael"),
            event(voice: "bf_emma"),
        ])
        XCTAssertEqual(summary.byVoice.map(\.key), ["af_heart", "am_michael", "bf_emma"])
        XCTAssertEqual(summary.byVoice.map(\.reads), [3, 2, 1])
    }

    func testSourceBreakdownUsesDisplayLabels() {
        let summary = summarize([event(source: .claudeCode), event(source: .article)])
        XCTAssertEqual(Set(summary.bySource.map(\.label)), ["Claude Code", "Article"])
    }

    func testAppBreakdownSkipsEventsWithNoApp() {
        let summary = summarize([
            event(app: "com.apple.Safari"),
            event(app: "com.apple.Safari"),
            event(app: nil),
        ])
        XCTAssertEqual(summary.byApp.count, 1)
        XCTAssertEqual(summary.byApp.first?.reads, 2)
    }

    func testHourBucketsCoverTheWholeDay() {
        let summary = summarize([event(hour: 9), event(hour: 9), event(hour: 23)])
        XCTAssertEqual(summary.byHour.count, 24)
        XCTAssertEqual(summary.byHour[9].reads, 2)
        XCTAssertEqual(summary.byHour[23].reads, 1)
        XCTAssertEqual(summary.byHour[0].reads, 0)
    }

    // MARK: - streaks

    func testCurrentStreakCountsConsecutiveDaysEndingToday() {
        let events = [event(daysAgo: 0), event(daysAgo: 1), event(daysAgo: 2)]
        let streaks = HistoryAnalytics.streakDays(events, now: now, calendar: calendar)
        XCTAssertEqual(streaks.current, 3)
    }

    /// Not having read anything *yet* today is a streak in progress, not a
    /// broken one — resetting it at midnight would be a lie until the day
    /// is actually over.
    func testStreakSurvivesADayThatHasNotHadAReadYet() {
        let events = [event(daysAgo: 1), event(daysAgo: 2)]
        XCTAssertEqual(
            HistoryAnalytics.streakDays(events, now: now, calendar: calendar).current, 2)
    }

    func testStreakBreaksOnAMissedDay() {
        let events = [event(daysAgo: 0), event(daysAgo: 2), event(daysAgo: 3)]
        let streaks = HistoryAnalytics.streakDays(events, now: now, calendar: calendar)
        XCTAssertEqual(streaks.current, 1)
        XCTAssertEqual(streaks.longest, 2)
    }

    func testStreakOfAnEmptyHistoryIsZero() {
        let streaks = HistoryAnalytics.streakDays([], now: now, calendar: calendar)
        XCTAssertEqual(streaks.current, 0)
        XCTAssertEqual(streaks.longest, 0)
    }

    /// Streaks describe the whole history, so a 7-day view must not report
    /// a 7-day streak when the real one is longer.
    func testStreakIsComputedOverFullHistoryNotTheVisibleWindow() {
        let events = (0..<12).map { event(daysAgo: $0) }
        let summary = summarize(events, range: .week)
        XCTAssertEqual(summary.totalReads, 7, "window still filters the totals")
        XCTAssertEqual(summary.currentStreakDays, 12, "but not the streak")
    }

    // MARK: - reading-time estimate

    func testEstimatedReadingTimeUsesTheStatedRate() {
        // 238 words at 238 wpm = exactly one minute.
        let summary = summarize([event(words: 238)])
        XCTAssertEqual(summary.estimatedReadingSeconds, 60, accuracy: 0.001)
    }

    // MARK: - formatting

    func testDurationString() {
        XCTAssertEqual(HistoryAnalytics.durationString(0), "0s")
        XCTAssertEqual(HistoryAnalytics.durationString(48), "48s")
        XCTAssertEqual(HistoryAnalytics.durationString(60), "1m")
        XCTAssertEqual(HistoryAnalytics.durationString(750), "12m 30s")
        XCTAssertEqual(HistoryAnalytics.durationString(3_600), "1h")
        XCTAssertEqual(HistoryAnalytics.durationString(15_120), "4h 12m")
    }

    func testCompactCount() {
        XCTAssertEqual(HistoryAnalytics.compactCount(0), "0")
        XCTAssertEqual(HistoryAnalytics.compactCount(9_999), "9,999")
        XCTAssertEqual(HistoryAnalytics.compactCount(12_400), "12.4k")
        XCTAssertEqual(HistoryAnalytics.compactCount(1_200_000), "1.2M")
    }

    func testPercentString() {
        XCTAssertEqual(HistoryAnalytics.percentString(0), "0%")
        XCTAssertEqual(HistoryAnalytics.percentString(0.666), "67%")
        XCTAssertEqual(HistoryAnalytics.percentString(1), "100%")
    }
}
