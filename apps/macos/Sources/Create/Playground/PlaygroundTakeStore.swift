// PlaygroundTakeStore.swift — keeps the Playground's takes across
// launches.
//
// Storage, under ~/Library/Application Support/Myna/playground/:
//   takes.json      small JSON index, newest first
//   <take-id>.wav   the audio, exactly as the daemon returned it
//
// Capped at `maxTakes`; the oldest take and its audio go when a new one
// arrives. The audio is the valuable part, so a damaged index never costs
// it: entries that no longer decode are dropped, and any WAV the index
// doesn't list is adopted back as a "recovered" take (duration and
// waveform come from the file itself; the text is gone). The damaged
// index is kept beside the new one for inspection.
//
// Concurrency: the published list is @MainActor. Writing a take's audio
// and computing its waveform happen off the main actor (a long take is
// tens of megabytes); the index itself is tiny and written in place.
import Foundation

@MainActor
final class PlaygroundTakeStore: ObservableObject {

    static let maxTakes = 50
    nonisolated static let indexFileName = "takes.json"
    static let indexVersion = 1

    /// Newest first.
    @Published private(set) var takes: [PlaygroundTake] = []
    /// How many takes the last load rebuilt from audio alone.
    @Published private(set) var recoveredCount = 0

    let directory: URL
    private let log = Log(.app)

    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Myna/playground", isDirectory: true)
    }

    init(directory: URL = PlaygroundTakeStore.defaultDirectory, loadImmediately: Bool = true) {
        self.directory = directory
        if loadImmediately { load() }
    }

    nonisolated var indexURL: URL { directory.appendingPathComponent(Self.indexFileName) }

    nonisolated func audioURL(for take: PlaygroundTake) -> URL {
        directory.appendingPathComponent(take.fileName)
    }

    func take(id: String) -> PlaygroundTake? {
        takes.first { $0.id == id }
    }

    // MARK: - adding

    /// Everything known about a fresh render, before it is a take.
    struct Draft: Sendable {
        var text: String
        var voice: String
        var voiceLabel: String
        var engine: String?
        var speed: Double?
        var renderMs: Int?
        /// `X-Myna-Duration-S`; the WAV header is the fallback.
        var reportedDuration: Double?
        var groupId: String?
        var audio: Data
    }

    struct Analysis: Sendable, Equatable {
        let duration: Double
        let bars: [UInt8]
    }

    @discardableResult
    func add(_ draft: Draft) async throws -> PlaygroundTake {
        let id = PlaygroundTake.newId()
        let url = directory.appendingPathComponent("\(id).wav")
        let audio = draft.audio
        let analysis = try await Task.detached(priority: .userInitiated) {
            try Self.writeAndAnalyse(audio, to: url)
        }.value
        let take = PlaygroundTake(
            id: id,
            text: draft.text,
            voice: draft.voice,
            voiceLabel: draft.voiceLabel,
            engine: draft.engine,
            speed: draft.speed,
            durationS: draft.reportedDuration ?? analysis.duration,
            renderMs: draft.renderMs,
            bars: analysis.bars,
            groupId: draft.groupId
        )
        takes.insert(take, at: 0)
        trimToCap()
        persist()
        return take
    }

    nonisolated static func writeAndAnalyse(_ audio: Data, to url: URL) throws -> Analysis {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: url, options: .atomic)
        return analyse(audio)
    }

    nonisolated static func analyse(_ audio: Data) -> Analysis {
        Analysis(
            duration: PlaygroundWAV.parse(audio)?.duration ?? 0,
            bars: PlaygroundWaveformMath.quantize(PlaygroundWAV.peaks(audio))
        )
    }

    // MARK: - removing

    func delete(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for take in takes where ids.contains(take.id) {
            try? FileManager.default.removeItem(at: audioURL(for: take))
        }
        takes.removeAll { ids.contains($0.id) }
        persist()
    }

    func deleteAll() {
        delete(ids: Set(takes.map(\.id)))
    }

    private func trimToCap() {
        while takes.count > Self.maxTakes {
            let dropped = takes.removeLast()
            try? FileManager.default.removeItem(at: audioURL(for: dropped))
        }
    }

    // MARK: - disk

    private struct Index: Codable {
        let version: Int
        let takes: [PlaygroundTake]
    }

    /// Reads the index one entry at a time, so one bad entry costs only
    /// its own metadata.
    private struct LossyIndex: Decodable {
        let takes: [LossyTake]
    }

    private struct LossyTake: Decodable {
        let take: PlaygroundTake?
        init(from decoder: Decoder) throws {
            take = try? PlaygroundTake(from: decoder)
        }
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var entries: [PlaygroundTake] = []
        var needsRewrite = false
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let index = try? decoder.decode(LossyIndex.self, from: data) {
                entries = index.takes.compactMap(\.take)
                needsRewrite = entries.count != index.takes.count
            } else {
                needsRewrite = true
            }
            if needsRewrite { keepDamagedIndex(data) }
        }

        // Drop duplicates and entries whose audio is gone.
        var known = Set<String>()
        let before = entries.count
        entries = entries.filter { take in
            known.insert(take.id).inserted && fm.fileExists(atPath: audioURL(for: take).path)
        }
        needsRewrite = needsRewrite || entries.count != before

        // Adopt audio the index doesn't list.
        let rebuilt = orphanedAudio(known: known).compactMap(Self.recoveredTake(from:))
        if !rebuilt.isEmpty {
            log.warn("playground: recovered \(rebuilt.count) take(s) from audio without an index entry")
            needsRewrite = true
        }
        entries += rebuilt
        entries.sort { $0.createdAt > $1.createdAt }

        takes = entries
        recoveredCount = rebuilt.count
        if takes.count > Self.maxTakes {
            trimToCap()
            needsRewrite = true
        }
        if needsRewrite { persist() }
    }

    private func keepDamagedIndex(_ data: Data) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = directory.appendingPathComponent("takes.damaged-\(stamp).json")
        try? data.write(to: backup, options: .atomic)
        log.warn("playground: takes index was damaged; kept a copy at \(backup.lastPathComponent)")
    }

    private func orphanedAudio(known: Set<String>) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            url.pathExtension.lowercased() == "wav"
                && !known.contains(url.deletingPathExtension().lastPathComponent)
        }
    }

    nonisolated static func recoveredTake(from url: URL) -> PlaygroundTake? {
        guard url.pathExtension.lowercased() == "wav",
              let audio = try? Data(contentsOf: url),
              PlaygroundWAV.parse(audio) != nil
        else { return nil }
        let analysis = analyse(audio)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return PlaygroundTake(
            id: url.deletingPathExtension().lastPathComponent,
            createdAt: modified,
            text: "",
            voice: "",
            voiceLabel: "Unknown voice",
            engine: nil,
            speed: nil,
            durationS: analysis.duration,
            renderMs: nil,
            bars: analysis.bars,
            recovered: true
        )
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(Index(version: Self.indexVersion, takes: takes))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            log.warn("playground: couldn't write the takes index: \(error.localizedDescription)")
        }
    }
}
