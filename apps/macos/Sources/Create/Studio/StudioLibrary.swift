// StudioLibrary.swift — the render jobs Studio shows, and what it can do
// to them.
//
// The daemon owns the jobs and files (RENDER_API.md §2); this is a cache
// of `GET /v2/renders` plus the actions. It's a shared object rather than
// view state so the list is already there when you come back to the pane,
// but it only polls while the pane is on screen: the pane's `.task` drives
// `pollLoop`, once a second while anything is rendering and every fifteen
// seconds otherwise.
//
// Retry needs the original text, which the daemon deletes once a job has
// rendered (and never returns). So each request Studio submits is kept
// in `StudioRequestStore`, keyed by job id, until the job finishes.
import Foundation

@MainActor
final class StudioLibrary: ObservableObject {
    private static var sharedInstance: StudioLibrary?

    /// The one library, talking to the daemon the rest of the app uses
    /// (a custom address in Settings included, as AppDelegate does).
    static func shared(baseURL: URL) -> StudioLibrary {
        if let existing = sharedInstance, existing.baseURL == baseURL { return existing }
        let library = StudioLibrary(client: RenderClient(baseURL: baseURL), baseURL: baseURL)
        sharedInstance = library
        return library
    }

    @Published private(set) var jobs: [RenderJob] = []
    @Published private(set) var loaded = false
    /// Why the list couldn't be fetched, in words for the pane.
    @Published private(set) var loadError: String?
    /// The last action that failed (cancel, delete, retry).
    @Published var actionError: String?
    @Published private(set) var busyIds: Set<String> = []

    let client: RenderClient
    let requests: StudioRequestStore
    private let baseURL: URL?
    private var refreshGeneration = 0

    static let fastPoll: UInt64 = 1_000_000_000
    static let slowPoll: UInt64 = 15_000_000_000

    init(client: RenderClient, requests: StudioRequestStore = StudioRequestStore(), baseURL: URL? = nil) {
        self.client = client
        self.requests = requests
        self.baseURL = baseURL
    }

    var hasActiveJobs: Bool { jobs.contains { $0.status.isActive } }

    /// Bytes of every finished file.
    var totalBytes: Int { jobs.reduce(0) { $0 + ($1.status == .done ? $1.bytes ?? 0 : 0) } }
    var doneCount: Int { jobs.filter { $0.status == .done }.count }

    func presentation(for job: RenderJob) -> StudioJobPresentation {
        // Ahead of a queued job: whatever is rendering, and older queued jobs.
        let ahead = job.status == .queued
            ? jobs.filter { other in
                other.id != job.id
                    && (other.status == .rendering || other.status == .encoding
                        || (other.status == .queued && other.createdAt < job.createdAt))
            }.count
            : 0
        return StudioJobPresentation.make(job: job, ahead: ahead, hasRequest: requests.has(job.id))
    }

    // MARK: - polling

    /// Runs until the calling task is cancelled (the pane disappears, or
    /// `hasActiveJobs` flips and the pane restarts it at the other rate).
    func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            let interval = hasActiveJobs ? Self.fastPoll : Self.slowPoll
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let fetched = try await client.renders()
            // A slower, older fetch must not overwrite a newer one.
            guard generation == refreshGeneration else { return }
            jobs = fetched.sorted { $0.createdAt > $1.createdAt }
            loadError = nil
            requests.prune(
                done: Set(jobs.filter { $0.status == .done }.map(\.id)),
                known: Set(jobs.map(\.id))
            )
        } catch {
            guard generation == refreshGeneration else { return }
            loadError = Self.describe(error)
        }
        loaded = true
    }

    // MARK: - actions

    @discardableResult
    func submit(_ request: RenderRequest) async throws -> RenderJob {
        let job = try await client.createRender(request)
        requests.save(request, for: job.id)
        insertOrReplace(job)
        await refresh()
        return job
    }

    func cancel(_ job: RenderJob) async {
        await perform(job) {
            let updated = try await self.client.cancelRender(id: job.id)
            self.insertOrReplace(updated)
        }
    }

    func delete(_ job: RenderJob) async {
        await perform(job) {
            try await self.client.deleteRender(id: job.id)
            self.requests.remove(job.id)
            self.jobs.removeAll { $0.id == job.id }
        }
    }

    /// Resubmits the original request. The failed entry is then removed,
    /// so a retry replaces it rather than leaving a second row behind.
    func retry(_ job: RenderJob) async {
        guard let request = requests.request(for: job.id) else {
            actionError = "Myna no longer has the text for “\(job.title)”, so it can't retry it. Start it again from Studio."
            return
        }
        await perform(job) {
            try await self.submit(request)
            try? await self.client.deleteRender(id: job.id)
            self.requests.remove(job.id)
            self.jobs.removeAll { $0.id == job.id }
        }
    }

    private func perform(_ job: RenderJob, _ action: @escaping @MainActor () async throws -> Void) async {
        busyIds.insert(job.id)
        defer { busyIds.remove(job.id) }
        actionError = nil
        do {
            try await action()
        } catch {
            actionError = Self.describe(error)
        }
        await refresh()
    }

    private func insertOrReplace(_ job: RenderJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    /// RenderAPIError already speaks plainly; these are the cases where
    /// Studio can say more about what to do.
    static func describe(_ error: Error) -> String {
        switch error as? RenderAPIError {
        case .transport?:
            return "Can't reach Myna's voice service. Check the Engine pane, then try again."
        case .notFound?, .http(405, _, _)?:
            return "This version of Myna's voice service can't make audio files. Restart it from the Engine pane."
        case .some(let apiError):
            return apiError.localizedDescription
        case nil:
            return error.localizedDescription
        }
    }
}

/// Each Studio request, kept until its job finishes so a failed or
/// cancelled job can be retried. One JSON file per job under
/// `~/Library/Application Support/Myna/studio/requests/`. A book's text is
/// a megabyte or two, so files are written once and never rewritten.
@MainActor
final class StudioRequestStore {
    private let directory: URL
    private var ids: Set<String>
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Records for jobs the daemon doesn't list are only pruned once they
    /// are this old, so a job created while a list request was in flight
    /// doesn't lose its record.
    static let orphanGrace: TimeInterval = 300

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Myna/studio/requests", isDirectory: true)
    }

    init(directory: URL = StudioRequestStore.defaultDirectory) {
        self.directory = directory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        ids = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }

    func has(_ id: String) -> Bool { ids.contains(id) }

    func save(_ request: RenderRequest, for id: String) {
        guard Self.isSafe(id), let data = try? encoder.encode(request) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: id), options: .atomic)
            ids.insert(id)
        } catch {
            Log(.app).warn("studio: couldn't keep the request for \(id): \(error.localizedDescription)")
        }
    }

    func request(for id: String) -> RenderRequest? {
        guard has(id), let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? decoder.decode(RenderRequest.self, from: data)
    }

    func remove(_ id: String) {
        guard ids.contains(id) else { return }
        try? FileManager.default.removeItem(at: url(for: id))
        ids.remove(id)
    }

    /// Drops records whose job has finished, and records the daemon no
    /// longer lists (deleted elsewhere, or a wiped library).
    func prune(done: Set<String>, known: Set<String>) {
        let now = Date()
        for id in ids {
            if done.contains(id) {
                remove(id)
            } else if !known.contains(id) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url(for: id).path)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                if now.timeIntervalSince(modified) > Self.orphanGrace { remove(id) }
            }
        }
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    /// Job ids come from the daemon; never let one name a path.
    private static func isSafe(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
