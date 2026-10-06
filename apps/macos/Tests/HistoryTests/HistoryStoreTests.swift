// HistoryStoreTests.swift — the durability guarantees the Dashboard leans
// on. Every test runs against its own temp directory; none touches the
// real ~/Library/Application Support/Myna/history.json.
import XCTest

@testable import Myna

@MainActor
final class HistoryStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        // No super.setUp(): sending the XCTestCase across actors fails CI's Swift 6 (see PillSettingsTests).
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-history-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> HistoryStore {
        HistoryStore(directory: directory, fileName: "history.json")
    }

    private func event(
        title: String = "Test",
        minutesAgo: Int = 0,
        outcome: ReadOutcome = .completed,
        voice: String = "af_heart",
        source: ReadSource = .selection,
        words: Int = 10,
        listened: Double = 30,
        audio: Double = 30
    ) -> ReadEvent {
        ReadEvent(
            startedAtMs: ReadEvent.currentTimeMs() - minutesAgo * 60_000,
            title: title,
            voice: voice,
            characters: words * 5,
            words: words,
            audioSeconds: audio,
            listenedSeconds: listened,
            outcome: outcome
        )
        .with(source: source)
    }

    // MARK: - persistence

    func testAppendPersistsAndReloads() throws {
        let store = makeStore()
        store.append(event(title: "First"))
        store.append(event(title: "Second"))
        store.flush()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.events.count, 2)
        // Newest first.
        XCTAssertEqual(reloaded.events.first?.title, "Second")
    }

    func testUpdateMutatesInPlaceAndSurvivesReload() throws {
        let store = makeStore()
        let id = store.append(event(title: "Live", outcome: .reading))
        store.update(id: id) { event in
            event.outcome = .completed
            event.listenedSeconds = 42
            event.firstAudioMs = 810
        }
        store.flush()

        let reloaded = makeStore()
        let event = try XCTUnwrap(reloaded.events.first)
        XCTAssertEqual(event.outcome, .completed)
        XCTAssertEqual(event.listenedSeconds, 42)
        XCTAssertEqual(event.firstAudioMs, 810)
    }

    /// Regression: the debounced write must actually run on the I/O queue.
    ///
    /// Every other test here calls `flush()`, and `DispatchQueue.sync`
    /// usually runs its block on the calling thread — so the whole suite
    /// passed while the real, asynchronous path crashed the app with
    /// EXC_BREAKPOINT the first time the debounce fired (a main-actor
    /// isolated closure executing on a background queue). This test waits
    /// out the debounce instead, which is the only way to exercise it.
    func testDebouncedWriteReachesDiskWithoutFlush() throws {
        let store = makeStore()
        store.append(event(title: "Debounced"))

        let landed = expectation(description: "history.json written by the debounce")
        let url = store.fileURL
        DispatchQueue.global().asyncAfter(deadline: .now() + HistoryStore.writeDebounce + 1.0) {
            if FileManager.default.fileExists(atPath: url.path) { landed.fulfill() }
        }
        wait(for: [landed], timeout: 5)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([ReadEvent].self, from: data)
        XCTAssertEqual(decoded.first?.title, "Debounced")
    }

    func testUpdateWithUnknownIdIsANoOp() {
        let store = makeStore()
        store.append(event())
        store.update(id: "does-not-exist") { $0.title = "clobbered" }
        XCTAssertEqual(store.events.first?.title, "Test")
    }

    /// A crash mid-read leaves `.reading` on disk. Loading must not show a
    /// phantom live row for a read that is definitely not playing.
    func testOrphanedReadingRecordIsClosedOnLoad() throws {
        let store = makeStore()
        store.append(event(title: "Interrupted", outcome: .reading))
        store.flush()

        let reloaded = makeStore()
        let event = try XCTUnwrap(reloaded.events.first)
        XCTAssertEqual(event.outcome, .stopped)
        XCTAssertNotNil(event.endedAtMs)
        XCTAssertNil(reloaded.liveEvent)
    }

    /// Losing the whole history to one bad byte would be the worst possible
    /// failure here, so a corrupt file is moved aside, not deleted.
    func testCorruptFileIsPreservedAndStoreStartsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        try Data("{ not json at all".utf8).write(to: url)

        let store = makeStore()
        XCTAssertTrue(store.events.isEmpty)

        let salvaged = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("history-corrupt-") }
        XCTAssertEqual(salvaged.count, 1, "the unreadable file must be kept for recovery")
    }

    // MARK: - retention

    func testPruneDropsOlderThanWindowAndKeepsLiveRead() {
        let store = makeStore()
        store.append(event(title: "old", minutesAgo: 60 * 24 * 40))
        store.append(event(title: "recent", minutesAgo: 60))
        store.append(event(title: "live", minutesAgo: 60 * 24 * 90, outcome: .reading))

        store.prune(olderThanDays: 30)

        let titles = store.events.map(\.title)
        XCTAssertFalse(titles.contains("old"))
        XCTAssertTrue(titles.contains("recent"))
        XCTAssertTrue(titles.contains("live"), "a read still in flight must never be pruned")
    }

    func testPruneWithZeroDaysKeepsEverything() {
        let store = makeStore()
        store.append(event(minutesAgo: 60 * 24 * 900))
        store.prune(olderThanDays: 0)
        XCTAssertEqual(store.events.count, 1)
    }

    func testDeleteAndClear() {
        let store = makeStore()
        let keep = store.append(event(title: "keep"))
        let drop = store.append(event(title: "drop"))
        store.delete(ids: [drop])
        XCTAssertEqual(store.events.map(\.id), [keep])
        store.clear()
        XCTAssertTrue(store.events.isEmpty)
    }

    // MARK: - export

    func testCSVEscapesQuotesCommasAndNewlines() {
        XCTAssertEqual(HistoryStore.csvEscape("plain"), "plain")
        XCTAssertEqual(HistoryStore.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(HistoryStore.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(HistoryStore.csvEscape("line\nbreak"), "\"line\nbreak\"")
    }

    /// A read titled `=HYPERLINK(...)` must not execute when the export is
    /// opened in Excel or Numbers.
    func testCSVNeutralisesFormulaInjection() {
        XCTAssertEqual(HistoryStore.csvEscape("=1+1"), "'=1+1")
        XCTAssertEqual(HistoryStore.csvEscape("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(HistoryStore.csvEscape("+cmd"), "'+cmd")
        XCTAssertEqual(HistoryStore.csvEscape("-cmd"), "'-cmd")
    }

    func testCSVExportHasHeaderAndOneRowPerEvent() {
        let store = makeStore()
        store.append(event(title: "One"))
        store.append(event(title: "Two"))
        let lines = store.exportCSV().split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("started_at,ended_at,title"))
    }

    /// The CSV is the shareable export; it must not carry the text of
    /// everything the user has ever had read aloud.
    func testCSVExportOmitsReadText() {
        let store = makeStore()
        store.append(
            ReadEvent(title: "Note", text: "a private secret sentence", voice: "af_heart"))
        XCTAssertFalse(store.exportCSV().contains("private secret sentence"))
    }

    func testJSONExportRoundTrips() throws {
        let store = makeStore()
        store.append(event(title: "Exported"))
        let data = try XCTUnwrap(store.exportJSON())
        let decoded = try JSONDecoder().decode([ReadEvent].self, from: data)
        XCTAssertEqual(decoded.first?.title, "Exported")
    }
}

// MARK: - helpers

extension ReadEvent {
    /// Test-only copy-with, so fixtures stay one expression.
    func with(source: ReadSource) -> ReadEvent {
        var copy = self
        copy.source = source
        return copy
    }
}
