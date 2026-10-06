// HistoryStore.swift — durable, observable store of every read.
//
// Storage: a single JSON array at
//   ~/Library/Application Support/Myna/history.json
// written atomically on a background queue, debounced so a burst of
// in-place mutations (first-audio latency, position samples, final
// outcome) costs one write rather than four.
//
// Why a plain JSON file and not SQLite / SwiftData:
//   • The whole working set is small — `maxEvents` caps it at 5,000
//     records, ~4 MB worst case with full text retained, and it is read
//     once at launch.
//   • Every record is mutated in place while it is live, which is the
//     awkward case for append-only JSONL.
//   • It stays greppable and trivially exportable, which matters for a
//     local-first app whose Account pane promises the user their data.
// If history ever needs to be queried rather than scanned, this class is
// the only thing that has to change — nothing above it sees the file.
//
// Concurrency: the published array is @MainActor (SwiftUI binds it
// directly); disk I/O hops to a private serial queue. `flush()` is
// synchronous and is called from applicationWillTerminate so a quit
// mid-debounce never loses the last read.
import Combine
import Foundation

@MainActor
public final class HistoryStore: ObservableObject {

    /// Process-wide store. AppDelegate injects this everywhere; tests
    /// build their own against a temp directory.
    public static let shared = HistoryStore()

    /// Newest first. The Dashboard binds straight to this.
    @Published public private(set) var events: [ReadEvent] = []

    /// Hard cap. Older records are dropped when it is exceeded — 5,000
    /// reads is years of heavy use, and the cap is what keeps a
    /// whole-file rewrite cheap.
    public static let maxEvents = 5_000

    /// Debounce before a mutation reaches disk.
    public static let writeDebounce: TimeInterval = 0.75

    private let directory: URL
    private let fileName: String
    private let io = DispatchQueue(label: "dev.myna.history.io", qos: .utility)
    private var writeWorkItem: DispatchWorkItem?
    private let log = Log(.app)

    public init(
        directory: URL = HistoryStore.defaultDirectory,
        fileName: String = "history.json",
        loadImmediately: Bool = true
    ) {
        self.directory = directory
        self.fileName = fileName
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if loadImmediately { load() }
    }

    public nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Myna", isDirectory: true)
    }

    public nonisolated var fileURL: URL { directory.appendingPathComponent(fileName) }

    // MARK: - reading

    /// Bytes the history occupies on disk. Surfaced in the Account pane
    /// so "where is my data" has a real answer.
    public var fileSizeBytes: Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// The read currently in flight, if any.
    public var liveEvent: ReadEvent? {
        events.first(where: { $0.outcome == .reading })
    }

    // MARK: - writing

    /// Insert a new record at the head. Returns the id so the caller can
    /// mutate it later.
    @discardableResult
    public func append(_ event: ReadEvent) -> String {
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
        schedulePersist()
        return event.id
    }

    /// Mutate a record in place. No-op if the id is gone (pruned, or
    /// cleared by the user mid-read).
    public func update(id: String, _ mutate: (inout ReadEvent) -> Void) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        mutate(&events[index])
        schedulePersist()
    }

    public func delete(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        events.removeAll { ids.contains($0.id) }
        schedulePersist()
    }

    public func clear() {
        events.removeAll()
        schedulePersist()
    }

    /// Drop everything older than `days`. Called by the retention setting
    /// in the Account pane; `nil`/0 means keep forever.
    public func prune(olderThanDays days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoffMs = Int((now.timeIntervalSince1970 - Double(days) * 86_400) * 1000)
        let before = events.count
        events.removeAll { $0.startedAtMs < cutoffMs && $0.outcome != .reading }
        if events.count != before { schedulePersist() }
    }

    /// Any record left `.reading` by a crash or a force-quit is not
    /// actually playing — close it out at load so the UI never shows a
    /// phantom live row. Called from `load()`.
    private func closeOrphanedReads() {
        var changed = false
        for index in events.indices where events[index].outcome == .reading {
            events[index].outcome = .stopped
            events[index].endedAtMs = events[index].endedAtMs ?? events[index].startedAtMs
            changed = true
        }
        if changed { schedulePersist() }
    }

    // MARK: - persistence

    private func schedulePersist() {
        writeWorkItem?.cancel()
        let item = Self.makeWriteItem(events, to: fileURL)
        writeWorkItem = item
        io.asyncAfter(deadline: .now() + Self.writeDebounce, execute: item)
    }

    /// Write immediately and wait. Called at terminate and by tests.
    public func flush() {
        writeWorkItem?.cancel()
        writeWorkItem = nil
        let item = Self.makeWriteItem(events, to: fileURL)
        io.sync(execute: item)
    }

    /// Build the disk-write work item OUTSIDE the main actor.
    ///
    /// This factory is `nonisolated` for a load-bearing reason. A closure
    /// formed inside a `@MainActor` member inherits main-actor isolation,
    /// and Swift 6 inserts a runtime isolation check into it — so running
    /// such a closure on `io` traps the process with EXC_BREAKPOINT the
    /// first time the debounce fires, taking the app down mid-read and
    /// losing exactly the record it was trying to save. (Same family of
    /// bug as the AVAudioPlayerNode completion crash in v0.4.1.) Forming
    /// the closure here gives it no isolation to check.
    ///
    /// `flush()` appeared to work under this bug only by accident:
    /// `DispatchQueue.sync` usually runs the block on the calling thread,
    /// so the check happened to pass on main. It is fixed here too rather
    /// than left resting on that.
    private nonisolated static func makeWriteItem(
        _ events: [ReadEvent], to url: URL
    ) -> DispatchWorkItem {
        DispatchWorkItem { writeSync(events, to: url) }
    }

    private nonisolated static func writeSync(_ events: [ReadEvent], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(events) else { return }
        // Atomic so a crash mid-write can't leave a truncated file that
        // would cost the user their whole history on next launch.
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoded = try JSONDecoder().decode([ReadEvent].self, from: data)
            events = decoded.sorted { $0.startedAtMs > $1.startedAtMs }
            closeOrphanedReads()
        } catch {
            // Never silently destroy the file — move it aside so it can be
            // recovered by hand, and start clean rather than refusing to launch.
            let backup = directory.appendingPathComponent(
                "history-corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            log.error("history: could not decode \(fileURL.lastPathComponent) (\(error)); moved to \(backup.lastPathComponent)")
            events = []
        }
    }

    // MARK: - export

    /// Pretty-printed JSON of the whole history, for the Account pane's
    /// export button.
    public func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(events)
    }

    /// Spreadsheet-friendly export. Deliberately excludes the read text —
    /// a CSV of everything you have ever had read aloud is not something
    /// to hand out by accident; JSON export carries it for a real backup.
    public func exportCSV() -> String {
        var out = "started_at,ended_at,title,source,mode,voice,speed,words,characters,"
        out += "audio_seconds,listened_seconds,first_audio_ms,app,outcome,url\n"
        let formatter = ISO8601DateFormatter()
        for event in events {
            let fields: [String] = [
                formatter.string(from: event.startedAt),
                event.endedAt.map { formatter.string(from: $0) } ?? "",
                event.title,
                event.source.rawValue,
                event.mode,
                event.voice,
                String(format: "%.2f", event.speed),
                String(event.words),
                String(event.characters),
                String(format: "%.1f", event.audioSeconds),
                String(format: "%.1f", event.listenedSeconds),
                event.firstAudioMs.map(String.init) ?? "",
                event.appName ?? event.appBundleId ?? "",
                event.outcome.rawValue,
                event.url ?? "",
            ]
            out += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        return out
    }

    /// RFC 4180 escaping. A leading `=`/`+`/`-`/`@` is also prefixed with
    /// a single quote so Excel and Numbers treat a read title as text
    /// rather than executing it as a formula.
    static func csvEscape(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
