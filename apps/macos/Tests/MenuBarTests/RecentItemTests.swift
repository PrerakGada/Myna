// RecentItemTests.swift — exercises display formatting + the ring-
// buffer trim behaviour (S06 Recent submenu).
import XCTest

@testable import Myna

final class RecentItemTests: XCTestCase {

    func test_truncated_title_keeps_short_titles_intact() {
        let item = RecentItem(title: "Hello world", voice: "Bella", createdAtMs: 0)
        XCTAssertEqual(item.truncatedTitle(), "Hello world")
    }

    func test_truncated_title_truncates_long_titles() {
        let item = RecentItem(title: String(repeating: "x", count: 100), voice: "v", createdAtMs: 0)
        let truncated = item.truncatedTitle(maxLength: 10)
        XCTAssertEqual(truncated.count, 11)  // 10 chars + "…"
        XCTAssertTrue(truncated.hasSuffix("…"))
    }

    func test_age_string_just_now_under_30s() {
        let nowMs = 10_000
        let item = RecentItem(title: "x", voice: "v", createdAtMs: nowMs - 5_000)  // 5s ago
        XCTAssertEqual(item.ageString(nowMs: nowMs), "just now")
    }

    func test_age_string_seconds_under_minute() {
        let nowMs = 1_000_000
        let item = RecentItem(title: "x", voice: "v", createdAtMs: nowMs - 45_000)  // 45s
        XCTAssertEqual(item.ageString(nowMs: nowMs), "45 s ago")
    }

    func test_age_string_minutes() {
        let nowMs = 10_000_000
        let item = RecentItem(title: "x", voice: "v", createdAtMs: nowMs - 120_000)  // 2 min
        XCTAssertEqual(item.ageString(nowMs: nowMs), "2 min ago")
    }

    func test_age_string_hours() {
        let nowMs = 100_000_000
        let item = RecentItem(title: "x", voice: "v", createdAtMs: nowMs - 7_200_000)  // 2h
        XCTAssertEqual(item.ageString(nowMs: nowMs), "2 h ago")
    }

    func test_display_line_format() {
        let nowMs = 100_000
        let item = RecentItem(title: "Designing Data", voice: "Bella", createdAtMs: nowMs - 100)
        let line = item.displayLine(nowMs: nowMs)
        XCTAssertEqual(line, "Bella · just now · \"Designing Data\"")
    }

    // MARK: - store ring buffer

    func test_store_keeps_at_most_max_items() {
        let suite = "test-recents-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = RecentItemsStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        for i in 0..<(RecentItemsStore.maxCount + 3) {
            store.add(RecentItem(title: "item \(i)", voice: "v", createdAtMs: i))
        }
        XCTAssertEqual(store.load().count, RecentItemsStore.maxCount)
    }

    func test_store_newest_first() {
        let suite = "test-recents-newest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = RecentItemsStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.add(RecentItem(title: "first", voice: "v", createdAtMs: 0))
        store.add(RecentItem(title: "second", voice: "v", createdAtMs: 1))
        store.add(RecentItem(title: "third", voice: "v", createdAtMs: 2))
        let loaded = store.load()
        XCTAssertEqual(loaded.first?.title, "third")
        XCTAssertEqual(loaded.last?.title, "first")
    }

    func test_store_clear_empties_persistence() {
        let suite = "test-recents-clear-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = RecentItemsStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.add(RecentItem(title: "x", voice: "v", createdAtMs: 0))
        store.clear()
        XCTAssertEqual(store.load(), [])
    }
}
