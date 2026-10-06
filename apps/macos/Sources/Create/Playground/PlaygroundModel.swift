// PlaygroundModel.swift — the Playground's state and the one path that
// turns text into takes.
//
// One model per app run, not per appearance: the Dashboard rebuilds a
// pane every time you switch to it, and a take rendering in the
// background should still land in the list when you come back, with the
// text you typed still in the editor. `session(for:)` hands out that one
// instance.
//
// What it talks to:
//   • DaemonClient — the active engine and its voices (read only; the
//     Playground never switches engines: only the active one renders).
//   • RenderClient — POST /v1/audio/speech for each take, /v2/formats and
//     /v2/transcode for Save as.
//   • PlaygroundTakeStore and PlaygroundPlayer — its own list and its own
//     speaker. The read pipeline (AudioPlayer, History, the pill) is never
//     involved.
import Foundation

/// The editor's text. Its own object so a keystroke re-renders the editor
/// and the controls, not every take in the list.
@MainActor
final class PlaygroundDraft: ObservableObject {
    @Published var text: String = ""
}

/// A one-line banner above the editor: what happened, and the one thing
/// to do about it.
struct PlaygroundNotice: Identifiable, Equatable {
    enum Kind: Equatable, Sendable {
        case error
        case info
    }

    enum Action: Equatable, Sendable {
        case openEngine
        case sendToStudio
        case openStudio
        case reveal(URL)

        var title: String {
            switch self {
            case .openEngine: return "Open Engine"
            case .sendToStudio: return "Send to Studio"
            case .openStudio: return "Open Studio"
            case .reveal: return "Show in Finder"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let message: String
    let action: Action?

    init(_ kind: Kind, _ message: String, action: Action? = nil) {
        self.kind = kind
        self.message = message
        self.action = action
    }
}

@MainActor
final class PlaygroundModel: ObservableObject {

    enum EngineState: Equatable {
        case loading
        case ready
        case unreachable
    }

    /// The render in flight. A comparison is several, one after another.
    struct Job: Equatable {
        let index: Int
        let total: Int
        let voiceLabel: String
        let startedAt: Date
    }

    static let maxCompareVoices = 4
    static let playWhenReadyKey = "playground.playWhenReady"
    static let saveFormatKey = "playground.saveFormat"

    let draft = PlaygroundDraft()
    let store: PlaygroundTakeStore
    let player: PlaygroundPlayer

    @Published private(set) var engineState: EngineState = .loading
    @Published private(set) var engine: EngineEntry?
    @Published private(set) var switchingTo: String?
    @Published private(set) var voices: [Voice] = []
    @Published var voiceId: String = ""
    @Published var speed: Double = 1.0
    @Published var compareVoiceIds: [String] = []
    @Published private(set) var job: Job?
    @Published var notice: PlaygroundNotice?
    @Published private(set) var formats: [AudioFormatInfo] = [PlaygroundExport.wav]
    @Published var selectedTakeId: String?
    @Published private(set) var isSaving = false
    @Published var playWhenReady: Bool {
        didSet { defaults.set(playWhenReady, forKey: Self.playWhenReadyKey) }
    }

    private let client: DaemonClient
    let render: RenderClient
    private let preferredVoice: @MainActor () -> String?
    let defaults: UserDefaults
    private var work: Task<Void, Never>?
    private var workToken: UUID?

    init(
        client: DaemonClient,
        render: RenderClient = .shared,
        store: PlaygroundTakeStore,
        player: PlaygroundPlayer = PlaygroundPlayer(),
        defaults: UserDefaults = .standard,
        preferredVoice: @escaping @MainActor () -> String? = { nil }
    ) {
        self.client = client
        self.render = render
        self.store = store
        self.player = player
        self.defaults = defaults
        self.preferredVoice = preferredVoice
        self.playWhenReady = defaults.object(forKey: Self.playWhenReadyKey) as? Bool ?? true
    }

    // MARK: - one per app run

    private static var sharedSession: PlaygroundModel?

    static func session(for context: DashboardContext) -> PlaygroundModel {
        if let sharedSession { return sharedSession }
        let settings = context.settings
        let model = PlaygroundModel(
            client: context.client,
            store: PlaygroundTakeStore(),
            preferredVoice: { [weak settings] in settings?.voice }
        )
        sharedSession = model
        return model
    }

    // MARK: - derived

    /// Engines without native speed (all but Kokoro today) ignore it, so
    /// the control is disabled for them rather than silently doing nothing.
    /// Unknown engine: let the daemon decide.
    var honoursSpeed: Bool { engine?.nativeSpeed ?? true }

    /// What a render is sent, and what a take records.
    var effectiveSpeed: Double? { honoursSpeed ? speed : nil }

    var isBusy: Bool { job != nil }

    var selectedTake: PlaygroundTake? {
        selectedTakeId.flatMap { store.take(id: $0) }
    }

    func label(for voiceId: String) -> String {
        voices.first { $0.id == voiceId }?.label ?? voiceId
    }

    /// Why Generate is unavailable, or nil when it isn't.
    func generateBlocker(for stats: PlaygroundText.Stats) -> String? {
        if isBusy { return "A take is rendering." }
        if stats.isEmpty { return "Type or paste something to hear." }
        if stats.isOverLimit { return "Too long for one take." }
        return nil
    }

    // MARK: - engine and voices

    func refresh() async {
        if engine == nil, voices.isEmpty { engineState = .loading }
        var reachedDaemon = false
        if let response = try? await client.engines() {
            engine = response.engines.first { $0.id == response.active }
            switchingTo = response.switchingTo
            reachedDaemon = true
        }
        if let list = try? await client.voices(forceRefresh: true) {
            voices = list
            reachedDaemon = true
        }
        engineState = reachedDaemon && !voices.isEmpty ? .ready : .unreachable
        chooseVoiceIfNeeded()
        compareVoiceIds = compareVoiceIds.filter { id in voices.contains { $0.id == id } }
        if let list = try? await render.formats() {
            formats = PlaygroundExport.menuFormats(list)
        }
    }

    /// Keeps the chosen voice if the engine still has it; otherwise the
    /// user's own voice, then the engine's default.
    func chooseVoiceIfNeeded() {
        guard !voices.isEmpty, !voices.contains(where: { $0.id == voiceId }) else { return }
        if let preferred = preferredVoice(), voices.contains(where: { $0.id == preferred }) {
            voiceId = preferred
        } else {
            voiceId = (voices.first { $0.isDefault } ?? voices[0]).id
        }
    }

    func setSaving(_ saving: Bool) {
        isSaving = saving
    }

    func toggleCompareVoice(_ id: String) {
        if let index = compareVoiceIds.firstIndex(of: id) {
            compareVoiceIds.remove(at: index)
        } else if compareVoiceIds.count < Self.maxCompareVoices {
            compareVoiceIds.append(id)
        }
    }

    // MARK: - rendering

    func generate() {
        let stats = PlaygroundText.stats(for: draft.text, speed: 1)
        guard generateBlocker(for: stats) == nil else { return }
        start(voiceIds: [voiceId.isEmpty ? nil : voiceId], groupId: nil)
    }

    /// The same text in each chosen voice, one after another, kept as one
    /// group so the list lays them side by side.
    func compare() {
        let stats = PlaygroundText.stats(for: draft.text, speed: 1)
        guard generateBlocker(for: stats) == nil, compareVoiceIds.count >= 2 else { return }
        let group = "g_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        start(voiceIds: compareVoiceIds, groupId: group)
    }

    func cancel() {
        work?.cancel()
        work = nil
        workToken = nil
        job = nil
    }

    private func start(voiceIds: [String?], groupId: String?) {
        let text = draft.text
        let speed = effectiveSpeed
        let token = UUID()
        workToken = token
        notice = nil
        // Set before the task starts so a second ⌘↩ can't slip in.
        job = Job(
            index: 0,
            total: voiceIds.count,
            voiceLabel: voiceIds.first.flatMap { $0 }.map(label(for:)) ?? "the default voice",
            startedAt: Date()
        )
        work = Task { [weak self] in
            await self?.run(text: text, voiceIds: voiceIds, speed: speed, groupId: groupId, token: token)
        }
    }

    private func run(text: String, voiceIds: [String?], speed: Double?, groupId: String?, token: UUID) async {
        defer {
            if workToken == token {
                job = nil
                work = nil
                workToken = nil
            }
        }
        var made: [PlaygroundTake] = []
        for (index, voice) in voiceIds.enumerated() {
            job = Job(
                index: index,
                total: voiceIds.count,
                voiceLabel: voice.map(label(for:)) ?? "the default voice",
                startedAt: Date()
            )
            do {
                made.append(try await renderTake(text: text, voice: voice, speed: speed, groupId: groupId))
            } catch {
                if Task.isCancelled || workToken != token { return }
                notice = PlaygroundErrors.notice(for: error)
                break
            }
            if Task.isCancelled || workToken != token { return }
        }
        guard let first = made.first else { return }
        selectedTakeId = first.id
        if made.count == 1, groupId == nil, playWhenReady {
            player.play(id: first.id, url: store.audioURL(for: first))
        }
        // The daemon answered with a different engine than the one shown:
        // it was switched while this pane was open.
        if let engineId = first.engine, engineId != engine?.id {
            await refresh()
        }
    }

    private func renderTake(text: String, voice: String?, speed: Double?, groupId: String?) async throws -> PlaygroundTake {
        let request = SpeechRequest(input: text, voice: voice, responseFormat: "wav", speed: speed)
        let result = try await render.speech(request)
        try Task.checkCancellation()
        let usedVoice = result.voice ?? voice ?? ""
        do {
            return try await store.add(PlaygroundTakeStore.Draft(
                text: text,
                voice: usedVoice,
                voiceLabel: takeVoiceLabel(voice: usedVoice, engineId: result.engine),
                engine: result.engine ?? engine?.id,
                speed: speed,
                renderMs: result.renderMs,
                reportedDuration: result.durationS,
                groupId: groupId,
                audio: result.audio
            ))
        } catch {
            throw PlaygroundStorageError(underlying: error.localizedDescription)
        }
    }

    /// The voice's label, except for a one-voice engine (Chatterbox,
    /// Soprano), whose only voice is called something like "Built-in
    /// voice": there the engine's name says more, in the list and in the
    /// file name.
    func takeVoiceLabel(voice: String, engineId: String?) -> String {
        if voices.count == 1, let engine, engineId == nil || engineId == engine.id {
            return engine.name
        }
        return voice.isEmpty ? "Default voice" : label(for: voice)
    }

    // MARK: - editor

    /// Text for files dropped on the editor, or nil (with a notice saying
    /// why) when one can't be used.
    func textForDroppedFiles(_ urls: [URL]) -> String? {
        var parts: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > PlaygroundText.maxDroppedFileBytes {
                let pretty = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                notice = PlaygroundNotice(
                    .error,
                    "\(name) is \(pretty), far more than one take can hold. Studio turns documents that long into audio files.",
                    action: .openStudio)
                return nil
            }
            do {
                guard let text = try PlaygroundText.loadDroppedFile(url) else {
                    notice = PlaygroundNotice(.error, "\(name) isn't plain text, so it can't be loaded here.")
                    return nil
                }
                parts.append(text)
            } catch {
                notice = PlaygroundNotice(.error, "Couldn't open \(name): \(error.localizedDescription)")
                return nil
            }
        }
        notice = nil
        return parts.joined(separator: "\n\n")
    }
}

/// A render succeeded but the take couldn't be written to disk.
struct PlaygroundStorageError: Error, LocalizedError {
    let underlying: String
    var errorDescription: String? {
        "The take rendered but couldn't be kept on disk (\(underlying)). Check that the disk isn't full."
    }
}

/// Turns a failure into a banner that says what happened and what to do.
enum PlaygroundErrors {
    static func notice(for error: Error) -> PlaygroundNotice {
        guard let renderError = error as? RenderAPIError else {
            return PlaygroundNotice(.error, error.localizedDescription)
        }
        let base = renderError.errorDescription ?? "Something went wrong."
        switch renderError {
        case .engineDown:
            return PlaygroundNotice(
                .error, base + " Open Engine and press Restart, then try again.", action: .openEngine)
        case .engineNotActive:
            return PlaygroundNotice(
                .error, base + " Only the active engine renders; Engine shows which one that is.", action: .openEngine)
        case .transport:
            return PlaygroundNotice(
                .error, base + " It may be restarting. If this keeps happening, check Engine.", action: .openEngine)
        case .inputTooLong:
            return PlaygroundNotice(.error, base, action: .sendToStudio)
        case .engineError:
            return PlaygroundNotice(.error, base + " Try again, or try another voice.")
        case .formatUnavailable:
            return PlaygroundNotice(.error, base + " WAV always works.")
        case .notFound:
            return PlaygroundNotice(
                .error,
                "Myna's voice service on this Mac is older than the app and can't make takes yet. "
                    + "Update Myna, then try again.")
        case .emptyInput, .notReady, .http, .decode:
            return PlaygroundNotice(.error, base)
        }
    }
}
