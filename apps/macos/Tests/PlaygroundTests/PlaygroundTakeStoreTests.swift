// PlaygroundTakeStoreTests.swift — takes survive closing the window, the
// list stays capped, deletes remove the audio, and a damaged index never
// costs the audio on disk.
import XCTest

@testable import Myna

@MainActor
final class PlaygroundTakeStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = PlaygroundFixtures.tempDirectory("store")
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private func makeStore() -> PlaygroundTakeStore {
        PlaygroundTakeStore(directory: directory)
    }

    private func wavFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".wav") }
    }

    func testAddWritesAudioAndIndexAndSurvivesReload() async throws {
        let store = makeStore()
        let take = try await store.add(PlaygroundFixtures.draft(text: "First take"))

        XCTAssertEqual(store.takes.map(\.id), [take.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: take).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.indexURL.path))
        XCTAssertEqual(take.durationS, 0.25, accuracy: 0.001, "falls back to the WAV header without a reported duration")
        XCTAssertEqual(take.bars.count, PlaygroundWAV.storedBarCount)

        let reloaded = makeStore()
        let back = try XCTUnwrap(reloaded.takes.first)
        XCTAssertEqual(reloaded.takes.count, 1)
        XCTAssertEqual(back.id, take.id)
        XCTAssertEqual(back.text, "First take")
        XCTAssertEqual(back.voice, take.voice)
        XCTAssertEqual(back.voiceLabel, take.voiceLabel)
        XCTAssertEqual(back.engine, "kokoro")
        XCTAssertEqual(back.speed, 1.0)
        XCTAssertEqual(back.renderMs, 120)
        XCTAssertEqual(back.bars, take.bars)
        XCTAssertEqual(back.createdAt.timeIntervalSince1970, take.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(reloaded.recoveredCount, 0)
    }

    func testReportedDurationWinsOverHeader() async throws {
        let store = makeStore()
        var draft = PlaygroundFixtures.draft()
        draft.reportedDuration = 9.5
        let take = try await store.add(draft)
        XCTAssertEqual(take.durationS, 9.5)
    }

    func testNewestFirst() async throws {
        let store = makeStore()
        let first = try await store.add(PlaygroundFixtures.draft(text: "one"))
        let second = try await store.add(PlaygroundFixtures.draft(text: "two"))
        XCTAssertEqual(store.takes.map(\.id), [second.id, first.id])
        XCTAssertEqual(makeStore().takes.map(\.id), [second.id, first.id])
    }

    func testCapDropsOldestTakeAndItsAudio() async throws {
        let store = makeStore()
        let tiny = PlaygroundFixtures.wav16([0, 100, -100, 0])
        var ids: [String] = []
        for index in 0..<(PlaygroundTakeStore.maxTakes + 2) {
            let take = try await store.add(PlaygroundFixtures.draft(text: "take \(index)", audio: tiny))
            ids.append(take.id)
        }
        XCTAssertEqual(store.takes.count, PlaygroundTakeStore.maxTakes)
        XCTAssertEqual(wavFiles().count, PlaygroundTakeStore.maxTakes)
        XCTAssertFalse(store.takes.contains { $0.id == ids[0] || $0.id == ids[1] }, "the two oldest go")
        XCTAssertEqual(store.takes.first?.id, ids.last)
        XCTAssertEqual(makeStore().takes.count, PlaygroundTakeStore.maxTakes)
    }

    func testDeleteRemovesEntryAndAudio() async throws {
        let store = makeStore()
        let keep = try await store.add(PlaygroundFixtures.draft(text: "keep"))
        let drop = try await store.add(PlaygroundFixtures.draft(text: "drop"))
        store.delete(ids: [drop.id])

        XCTAssertEqual(store.takes.map(\.id), [keep.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(for: drop).path))
        XCTAssertEqual(makeStore().takes.map(\.id), [keep.id])
    }

    func testDeleteAll() async throws {
        let store = makeStore()
        try await store.add(PlaygroundFixtures.draft())
        try await store.add(PlaygroundFixtures.draft())
        store.deleteAll()
        XCTAssertTrue(store.takes.isEmpty)
        XCTAssertTrue(wavFiles().isEmpty)
        XCTAssertTrue(makeStore().takes.isEmpty)
    }

    func testUnreadableIndexRecoversTakesFromAudio() async throws {
        let store = makeStore()
        let first = try await store.add(PlaygroundFixtures.draft(text: "one"))
        let second = try await store.add(PlaygroundFixtures.draft(text: "two"))
        try Data("{ this is not json".utf8).write(to: store.indexURL)

        let recovered = makeStore()
        XCTAssertEqual(Set(recovered.takes.map(\.id)), [first.id, second.id], "no audio is lost")
        XCTAssertEqual(recovered.recoveredCount, 2)
        XCTAssertTrue(recovered.takes.allSatisfy(\.isRecovered))
        XCTAssertTrue(recovered.takes.allSatisfy { $0.text.isEmpty })
        XCTAssertEqual(recovered.takes.first?.durationS ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(recovered.takes.first?.bars.count, PlaygroundWAV.storedBarCount)

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasPrefix("takes.damaged-") }, "the damaged index is kept")

        // The rewritten index is valid: the next launch recovers nothing.
        XCTAssertEqual(makeStore().recoveredCount, 0)
        XCTAssertEqual(makeStore().takes.count, 2)
    }

    func testOneBadEntryCostsOnlyItsOwnMetadata() async throws {
        let store = makeStore()
        let good = try await store.add(PlaygroundFixtures.draft(text: "good"))
        let bad = try await store.add(PlaygroundFixtures.draft(text: "bad"))

        var index = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL)) as? [String: Any])
        var entries = try XCTUnwrap(index["takes"] as? [[String: Any]])
        let badIndex = try XCTUnwrap(entries.firstIndex { ($0["id"] as? String) == bad.id })
        entries[badIndex]["duration_s"] = "not a number"
        index["takes"] = entries
        try JSONSerialization.data(withJSONObject: index).write(to: store.indexURL)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.take(id: good.id)?.text, "good", "the good entry keeps its text")
        XCTAssertEqual(reloaded.take(id: bad.id)?.isRecovered, true, "the bad one is rebuilt from its audio")
        XCTAssertEqual(reloaded.recoveredCount, 1)
    }

    func testEntryWhoseAudioIsGoneIsDropped() async throws {
        let store = makeStore()
        let kept = try await store.add(PlaygroundFixtures.draft(text: "kept"))
        let lost = try await store.add(PlaygroundFixtures.draft(text: "lost"))
        try FileManager.default.removeItem(at: store.audioURL(for: lost))

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.takes.map(\.id), [kept.id])
        XCTAssertEqual(reloaded.recoveredCount, 0)
    }

    func testStrayNonAudioFilesAreIgnored() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: directory.appendingPathComponent("junk.wav"))
        try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let store = makeStore()
        XCTAssertTrue(store.takes.isEmpty)
    }

    func testEmptyDirectoryLoadsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.takes.isEmpty)
        XCTAssertEqual(store.recoveredCount, 0)
    }
}
