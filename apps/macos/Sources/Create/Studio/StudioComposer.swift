// StudioComposer.swift — the state behind "New conversion": where the
// text comes from, then the review before anything is rendered.
//
// Three ways in (paste, a web page, files) all end in `begin(document:)`
// and the same review. The review never switches engines: it lists the
// active engine's voices and names that engine, because a render that
// switched would pull the model out from under a live read (RENDER_API.md).
//
// Optional cleanups are applied to the imported text on every toggle,
// keeping the user's section switches; turning "skip very short sections"
// on or off re-decides only the sections it applies to.
//
// Text too long for a Playground take arrives through PlaygroundHandoff;
// StudioPane takes it on appear and opens the review with it.
import Foundation

struct StudioReviewSection: Identifiable, Equatable {
    let id: Int
    let title: String
    /// After the optional cleanups.
    let text: String
    let words: Int
    let skippable: Bool
    var included: Bool
}

@MainActor
final class StudioComposer: ObservableObject {
    enum Stage: Equatable {
        case paste
        case web
        case importing(String)
        case review
    }

    /// Drives the sheet. Every `start…` presents it.
    @Published var isPresented = false
    @Published var stage: Stage = .paste
    @Published var error: String?

    // paste
    @Published var pastedText = ""

    // web
    @Published var urlString = ""
    @Published private(set) var fetching = false
    @Published private(set) var fetched: ImportedDocument?
    @Published private(set) var fetchedByline: String?

    // review
    @Published private(set) var document: ImportedDocument?
    @Published var title = ""
    @Published var sections: [StudioReviewSection] = []
    @Published var cleanup = CleanupOptions(removeURLs: true, removeCitations: false, skipShortSections: false) {
        didSet {
            guard cleanup != oldValue else { return }
            rebuildSections(skipChanged: cleanup.skipShortSections != oldValue.skipShortSections)
        }
    }
    @Published private(set) var voices: [Voice] = []
    @Published var voiceId = ""
    @Published private(set) var engineName: String?
    @Published private(set) var engineId: String?
    @Published private(set) var nativeSpeed = true
    @Published private(set) var formats: [AudioFormatInfo] = []
    @Published var formatId = "m4a"
    @Published var speed: Double = 1.0
    @Published var pauseMs = 1_500
    @Published private(set) var contextError: String?
    @Published private(set) var submitting = false
    @Published private(set) var wordsPerMinute = StudioEstimate.fallbackWordsPerMinute

    private let client: DaemonClient
    private let settings: SettingsViewModel
    private let history: HistoryStore
    private var importTask: Task<Void, Never>?

    /// Formats a render job can be (RENDER_API.md §2), in the order offered.
    static let renderFormats = ["m4a", "mp3", "aac", "flac", "opus", "wav"]
    static let pauseChoices = [0, 500, 1_000, 1_500, 2_000, 3_000]

    init(client: DaemonClient, settings: SettingsViewModel, history: HistoryStore) {
        self.client = client
        self.settings = settings
        self.history = history
    }

    // MARK: - starting

    func startPaste(text: String = "") {
        reset()
        pastedText = text
        stage = .paste
        isPresented = true
    }

    func startWeb(url: String = "") {
        reset()
        urlString = url
        stage = .web
        isPresented = true
    }

    func startFiles(_ urls: [URL]) {
        reset()
        guard !urls.isEmpty else { return }
        let names = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        stage = .importing("Reading \(names)…")
        isPresented = true
        importTask = Task { [weak self] in
            do {
                let document = try await DocumentImporter.importFiles(urls)
                guard !Task.isCancelled else { return }
                self?.begin(document: document)
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription
            }
        }
    }

    func cancelWork() {
        importTask?.cancel()
        importTask = nil
    }

    private func reset() {
        cancelWork()
        error = nil
        pastedText = ""
        urlString = ""
        fetched = nil
        fetchedByline = nil
        fetching = false
        document = nil
        title = ""
        sections = []
        submitting = false
    }

    // MARK: - paste and web

    func continueFromPaste() {
        let document = DocumentImporter.pastedText(pastedText)
        guard document.wordCount > 0 else {
            error = "Paste some text first."
            return
        }
        begin(document: document)
    }

    /// Adds `https://` to a bare "example.com/article".
    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return trimmed }
        return "https://" + trimmed
    }

    func fetchURL() async {
        let url = Self.normalizedURL(urlString)
        guard !url.isEmpty else { return }
        urlString = url
        fetching = true
        error = nil
        fetched = nil
        defer { fetching = false }
        do {
            let response = try await client.extract(url: url)
            let document = DocumentImporter.webPage(title: response.title, text: response.text ?? "", url: url)
            guard document.wordCount > 0 else {
                error = "That page has no article text Myna can find. Copy the text and paste it instead."
                return
            }
            fetched = document
            fetchedByline = response.byline
        } catch let daemonError as DaemonError {
            error = Self.describe(daemonError)
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func describe(_ error: DaemonError) -> String {
        switch error {
        case .invalidURL:
            return "That isn't a web address Myna can open. It should start with https://."
        case .extractFailed:
            return "Couldn't find article text on that page. Some sites block readers or need a login; "
                + "copy the text and paste it instead."
        case .transport:
            return "Can't reach Myna's voice service. Check the Engine pane, then try again."
        case .http(let status, let body):
            return "The page couldn't be fetched (HTTP \(status))." + (body.isEmpty ? "" : " \(body)")
        default:
            return "The page couldn't be fetched: \(error)"
        }
    }

    func continueFromWeb() {
        guard let fetched else { return }
        begin(document: fetched)
    }

    // MARK: - review

    func begin(document: ImportedDocument) {
        importTask = nil
        error = nil
        self.document = document
        title = document.title
        speed = settings.defaultSpeed
        sections = []
        let defaults = CleanupOptions.defaults(for: document.kind, sectionCount: document.sections.count)
        if cleanup == defaults {
            rebuildSections(skipChanged: false)
        } else {
            cleanup = defaults  // didSet rebuilds
        }
        stage = .review
    }

    private func rebuildSections(skipChanged: Bool) {
        guard let document else { return }
        let previous = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.included) })
        sections = document.sections.enumerated().map { index, raw in
            let text = cleanup.apply(to: raw.text)
            let words = StudioText.wordCount(text)
            let skippable = document.sections.count > 1 && CleanupOptions.isSkippable(title: raw.title, words: words)
            let byDefault = raw.includedByDefault && !(cleanup.skipShortSections && skippable)
            let included: Bool
            if let kept = previous[index], !(skipChanged && skippable) {
                included = kept
            } else {
                included = byDefault
            }
            return StudioReviewSection(
                id: index, title: raw.title, text: text, words: words, skippable: skippable, included: included)
        }
    }

    func setAll(included: Bool) {
        for index in sections.indices where sections[index].words > 0 {
            sections[index].included = included
        }
    }

    var includedSections: [StudioReviewSection] { sections.filter { $0.included && $0.words > 0 } }
    var includedWords: Int { includedSections.reduce(0) { $0 + $1.words } }

    /// Speed the engine will actually use.
    var effectiveSpeed: Double { nativeSpeed ? speed : 1.0 }

    func estimate(words: Int) -> Double {
        StudioEstimate.seconds(words: words, speed: effectiveSpeed, wordsPerMinute: wordsPerMinute)
    }

    var totalEstimate: Double {
        let included = includedSections
        return StudioEstimate.totalSeconds(
            sectionWords: included.map(\.words),
            speed: effectiveSpeed,
            wordsPerMinute: wordsPerMinute,
            pauseMs: included.count > 1 ? pauseMs : 0
        )
    }

    var selectedFormat: AudioFormatInfo? { formats.first { $0.id == formatId } }

    /// The voice Myna reads with, so the review can point it out.
    var usualVoiceId: String { settings.voice }

    /// Voices, the active engine, formats and this Mac's reading pace.
    /// Failures leave sensible defaults and a note; they never block Start.
    func loadContext(library: StudioLibrary) async {
        contextError = nil
        let client = self.client
        let renderClient = library.client
        async let fetchedVoices = try? client.voices(forceRefresh: true)
        async let fetchedEngines = try? client.engines()
        async let fetchedFormats = try? renderClient.formats()

        if let list = await fetchedVoices {
            voices = list
            let preferred = settings.voice
            voiceId = list.first { $0.id == preferred }?.id
                ?? list.first { $0.isDefault }?.id
                ?? list.first?.id ?? ""
        } else {
            voices = []
            voiceId = ""
            contextError = "Couldn't load the voice list, so the engine's own default voice will be used."
        }

        if let engines = await fetchedEngines,
           let active = engines.engines.first(where: { $0.id == engines.active }) {
            engineName = active.name
            engineId = active.id
            nativeSpeed = active.nativeSpeed
        } else {
            engineName = nil
            engineId = nil
            nativeSpeed = true
        }

        if let all = await fetchedFormats {
            formats = Self.renderFormats.compactMap { id in all.first { $0.id == id } }
        } else {
            formats = [AudioFormatInfo(
                id: "m4a", label: "M4A (AAC)", available: true, ext: "m4a", mime: "audio/mp4", reason: nil)]
        }
        if selectedFormat?.available != true {
            formatId = formats.first { $0.id == "m4a" && $0.available }?.id
                ?? formats.first { $0.available }?.id ?? "m4a"
        }

        wordsPerMinute = StudioEstimate.wordsPerMinute(
            renders: library.jobs, engine: engineId, history: history.events)
    }

    // MARK: - submitting

    /// How to render, as chosen in the review.
    struct RenderChoices: Equatable {
        var voice: String
        /// nil when the engine can't change speed.
        var speed: Double?
        var format: String
        var pauseMs: Int
    }

    /// The request for what's on screen, or nil if nothing is included.
    /// One included section goes as `text` (no chapter markers for a
    /// one-chapter file); several go as `sections`.
    static func buildRequest(
        title: String,
        fallbackTitle: String,
        sections: [StudioReviewSection],
        choices: RenderChoices,
        sourceKind: StudioSourceKind? = nil
    ) -> RenderRequest? {
        let included = sections.filter { $0.included && $0.words > 0 }
        guard !included.isEmpty else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? fallbackTitle : trimmed
        let voice = choices.voice.isEmpty ? nil : choices.voice
        if included.count == 1 {
            return RenderRequest(
                title: name, text: included[0].text, voice: voice, speed: choices.speed,
                format: choices.format, source: "studio", sourceKind: sourceKind?.rawValue)
        }
        return RenderRequest(
            title: name,
            sections: included.map { RenderSection(title: $0.title, text: $0.text) },
            voice: voice,
            speed: choices.speed,
            format: choices.format,
            source: "studio",
            sectionPauseMs: choices.pauseMs,
            // The daemon applies its article cleanup (captions, ads,
            // reference lists) to web, pdf and epub documents.
            sourceKind: sourceKind?.rawValue
        )
    }

    var request: RenderRequest? {
        Self.buildRequest(
            title: title,
            fallbackTitle: document?.title ?? "Untitled",
            sections: sections,
            choices: RenderChoices(
                voice: voiceId, speed: nativeSpeed ? speed : nil, format: formatId, pauseMs: pauseMs),
            sourceKind: document?.kind
        )
    }

    /// Returns true once the job is queued.
    func submit(to library: StudioLibrary) async -> Bool {
        guard let request else {
            error = "Switch on at least one section to render."
            return false
        }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            try await library.submit(request)
            return true
        } catch {
            self.error = "Couldn't start the render. " + StudioLibrary.describe(error)
            return false
        }
    }
}
