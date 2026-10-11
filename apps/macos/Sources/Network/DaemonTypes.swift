// DaemonTypes.swift — canonical wire types for the Myna daemon HTTP API.
// Mirrors docs/native-app/API_CONTRACT.md § 4 verbatim. Do not deviate.
import Foundation

public enum DaemonState: String, Codable, Sendable {
    case idle
    case synthesizing
    case streaming
    case down
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DaemonState(rawValue: raw) ?? .unknown
    }
}

public struct EngineInfo: Codable, Sendable, Equatable {
    public let url: String
    public let status: String  // "up" | "down"
    public let model: String
    public let lastCheckAgeS: Double
    /// Catalog id and display name of the active engine (nil on daemons
    /// older than the engine catalog).
    public let id: String?
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case url
        case status
        case model
        case lastCheckAgeS = "last_check_age_s"
        case id
        case name
    }

    public init(
        url: String, status: String, model: String, lastCheckAgeS: Double,
        id: String? = nil, name: String? = nil
    ) {
        self.url = url
        self.status = status
        self.model = model
        self.lastCheckAgeS = lastCheckAgeS
        self.id = id
        self.name = name
    }
}

public struct DaemonInfo: Codable, Sendable, Equatable {
    public let version: String
    public let uptimeS: Double
    public let pid: Int

    enum CodingKeys: String, CodingKey {
        case version
        case pid
        case uptimeS = "uptime_s"
    }

    public init(version: String, uptimeS: Double, pid: Int) {
        self.version = version
        self.uptimeS = uptimeS
        self.pid = pid
    }
}

public struct DaemonConfig: Codable, Sendable, Equatable {
    public let voice: String
    public let speed: Double
    public let langCode: String
    public let chunkChars: Int
    public let summaryModel: String

    enum CodingKeys: String, CodingKey {
        case voice
        case speed
        case langCode = "lang_code"
        case chunkChars = "chunk_chars"
        case summaryModel = "summary_model"
    }

    public init(voice: String, speed: Double, langCode: String, chunkChars: Int, summaryModel: String) {
        self.voice = voice
        self.speed = speed
        self.langCode = langCode
        self.chunkChars = chunkChars
        self.summaryModel = summaryModel
    }
}

public struct RegistryItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let ageS: Int
    public let preview: String

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case preview
        case ageS = "age_s"
    }

    public init(id: String, label: String, ageS: Int, preview: String) {
        self.id = id
        self.label = label
        self.ageS = ageS
        self.preview = preview
    }
}

public struct RegistryInfo: Codable, Sendable, Equatable {
    public let count: Int
    public let items: [RegistryItem]

    public init(count: Int, items: [RegistryItem]) {
        self.count = count
        self.items = items
    }
}

public struct DaemonStatus: Codable, Sendable, Equatable {
    public let state: DaemonState
    public let engine: EngineInfo
    public let daemon: DaemonInfo
    public let config: DaemonConfig
    public let registry: RegistryInfo
    /// Optional top-level mirror of `engine.status == "up"`. Some daemon
    /// builds expose `engine_up` directly on the status response; older
    /// ones only have the nested `engine.status` string. Prefer this
    /// when present, fall back to `engine.status` otherwise (see
    /// `isEngineUp`).
    public let engineUp: Bool?

    enum CodingKeys: String, CodingKey {
        case state
        case engine
        case daemon
        case config
        case registry
        case engineUp = "engine_up"
    }

    /// Canonical "engine reachable" flag combining the optional top-level
    /// `engine_up` and the nested `engine.status` string. Returns `false`
    /// if the daemon explicitly says the engine is down.
    public var isEngineUp: Bool {
        if let engineUp { return engineUp }
        return engine.status.lowercased() == "up"
    }

    public init(
        state: DaemonState,
        engine: EngineInfo,
        daemon: DaemonInfo,
        config: DaemonConfig,
        registry: RegistryInfo,
        engineUp: Bool? = nil
    ) {
        self.state = state
        self.engine = engine
        self.daemon = daemon
        self.config = config
        self.registry = registry
        self.engineUp = engineUp
    }
}

public struct Voice: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let lang: String
    public let isDefault: Bool
    /// "builtin", or the user's own: "clip" (a voice copied from a
    /// recording) or "blend" (Kokoro voices mixed). Nil from older daemons.
    public let kind: String?
    /// How pickers file it: "American English", "Built-in", "Your voices"…
    public let group: String?
    public let gender: String?
    /// Kokoro's own quality grade (A … F), where the model card gives one.
    public let grade: String?
    public let detail: String?
    /// Attribution a licensed clip requires (CC BY).
    public let credit: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case lang
        case isDefault = "default"
        case kind
        case group
        case gender
        case grade
        case detail
        case credit
    }

    public init(
        id: String,
        label: String,
        lang: String,
        isDefault: Bool,
        kind: String? = nil,
        group: String? = nil,
        gender: String? = nil,
        grade: String? = nil,
        detail: String? = nil,
        credit: String? = nil
    ) {
        self.id = id
        self.label = label
        self.lang = lang
        self.isDefault = isDefault
        self.kind = kind
        self.group = group
        self.gender = gender
        self.grade = grade
        self.detail = detail
        self.credit = credit
    }

    /// A clip or blend the user made, which they can rename and delete.
    public var isUserMade: Bool { kind == "clip" || kind == "blend" }
}

public struct VoicesResponse: Codable, Sendable, Equatable {
    public let voices: [Voice]
    /// "down" when the engine is unreachable; absent otherwise.
    public let engine: String?
    public let activeEngine: VoicesEngineInfo?

    enum CodingKeys: String, CodingKey {
        case voices
        case engine
        case activeEngine = "active_engine"
    }

    public init(voices: [Voice], engine: String? = nil, activeEngine: VoicesEngineInfo? = nil) {
        self.voices = voices
        self.engine = engine
        self.activeEngine = activeEngine
    }
}

public enum SynthesizeMode: String, Codable, Sendable {
    case full
    case summary
}

public struct SynthesizeRequest: Codable, Sendable, Equatable {
    public var text: String?
    public var url: String?
    public var voice: String?
    public var speed: Double
    public var mode: SynthesizeMode
    public var chunkChars: Int?
    public var sessionId: String?
    /// Bundle identifier of the frontmost app at the time of the
    /// request. Daemon uses this to look up the voice wardrobe.
    public var bundleId: String?
    /// Where the text came from (`ReadSource.rawValue`). Picks the daemon's
    /// text-cleanup preset: Claude Code replies and articles get their own.
    public var source: String?
    /// `.literal` reads the text exactly as written. nil = the daemon's
    /// default, `.auto`.
    public var prep: TextPrep?
    /// `mode: .summary` only: the style the daemon's Ollama fallback writes
    /// (`SummaryStyle.rawValue`). Absent on full reads, including a summary
    /// Apple Intelligence already wrote in the app. See Sources/Summaries/.
    public var summaryStyle: String?

    enum CodingKeys: String, CodingKey {
        case text
        case url
        case voice
        case speed
        case mode
        case chunkChars = "chunk_chars"
        case sessionId = "session_id"
        case bundleId = "bundle_id"
        case source
        case prep
        case summaryStyle = "summary_style"
    }

    public init(
        text: String? = nil,
        url: String? = nil,
        voice: String? = nil,
        speed: Double = 1.0,
        mode: SynthesizeMode = .full,
        chunkChars: Int? = nil,
        sessionId: String? = nil,
        bundleId: String? = nil,
        source: String? = nil,
        prep: TextPrep? = nil
    ) {
        self.text = text
        self.url = url
        self.voice = voice
        self.speed = speed
        self.mode = mode
        self.chunkChars = chunkChars
        self.sessionId = sessionId
        self.bundleId = bundleId
        self.source = source
        self.prep = prep
    }
}

public struct SynthesizedChunk: Sendable, Equatable {
    public let index: Int
    public let totalEstimate: Int
    public let textPreview: String
    public let wavData: Data
    /// The whole chunk as spoken (`X-Chunk-Text-Full`). Nil from a daemon
    /// older than the sentence transcript, which sends only the preview.
    public let fullText: String?
    /// When each word of `fullText` is spoken (`X-Chunk-Words`), for the
    /// pill's live captions. Empty from an older daemon.
    public let words: [TimedWord]

    public init(
        index: Int, totalEstimate: Int, textPreview: String, wavData: Data,
        fullText: String? = nil, words: [TimedWord] = []
    ) {
        self.index = index
        self.totalEstimate = totalEstimate
        self.textPreview = textPreview
        self.wavData = wavData
        self.fullText = fullText
        self.words = words
    }

    /// What this chunk said, for the transcript: the full text, or the
    /// 200-character preview when the daemon didn't send it.
    public var spokenText: String { fullText ?? textPreview }
}

/// Response-level metadata for a /v2/synthesize call. Today this carries
/// the X-Myna-Detected-Lang / X-Myna-Lang-Mismatch headers used to drive
/// the "Detected: Spanish — switch voice?" UX.
public struct SynthesizeMetadata: Sendable, Equatable {
    /// ISO-639-1 code, if the daemon's detector was confident enough.
    public let detectedLang: String?
    /// True if the detected language differs from the daemon's
    /// configured cfg["lang_code"].
    public let langMismatch: Bool

    public init(detectedLang: String?, langMismatch: Bool) {
        self.detectedLang = detectedLang
        self.langMismatch = langMismatch
    }
}

public struct ExtractRequest: Codable, Sendable, Equatable {
    public let url: String

    public init(url: String) {
        self.url = url
    }
}

public struct ExtractResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let text: String?
    public let title: String?
    public let byline: String?
    public let reason: String?

    public init(ok: Bool, text: String? = nil, title: String? = nil, byline: String? = nil, reason: String? = nil) {
        self.ok = ok
        self.text = text
        self.title = title
        self.byline = byline
        self.reason = reason
    }
}

public struct SummarizeRequest: Codable, Sendable, Equatable {
    public let text: String
    /// `SummaryStyle.rawValue`; nil lets the daemon use its default (TL;DR).
    public let summaryStyle: String?

    enum CodingKeys: String, CodingKey {
        case text
        case summaryStyle = "summary_style"
    }

    public init(text: String, summaryStyle: String? = nil) {
        self.text = text
        self.summaryStyle = summaryStyle
    }
}

public struct SummarizeResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let summary: String?
    public let reason: String?

    public init(ok: Bool, summary: String? = nil, reason: String? = nil) {
        self.ok = ok
        self.summary = summary
        self.reason = reason
    }
}

public struct VoiceWardrobeResponse: Codable, Sendable, Equatable {
    /// `{ bundle_id: voice_id }` mapping from the daemon.
    public let mappings: [String: String]

    public init(mappings: [String: String]) {
        self.mappings = mappings
    }
}

public struct VoiceWardrobeUpsertRequest: Codable, Sendable, Equatable {
    public let bundleId: String
    public let voiceId: String?

    enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case voiceId = "voice_id"
    }

    public init(bundleId: String, voiceId: String?) {
        self.bundleId = bundleId
        self.voiceId = voiceId
    }
}

public struct ModelStatusResponse: Codable, Sendable, Equatable {
    public let modelLoaded: Bool
    public let engineURL: String
    public let daemonRssMb: Double
    public let daemonPID: Int
    /// False on the current Myna daemon because the TTS engine lives
    /// out-of-process. Swift UI hides the "Pause Myna" toggle when this
    /// is false.
    public let suspendSupported: Bool
    /// Physical footprint of the engine process (where the model lives).
    public let engineMemoryMb: Double?
    public let enginePID: Int?

    enum CodingKeys: String, CodingKey {
        case modelLoaded = "model_loaded"
        case engineURL = "engine_url"
        case daemonRssMb = "daemon_rss_mb"
        case daemonPID = "daemon_pid"
        case suspendSupported = "suspend_supported"
        case engineMemoryMb = "engine_memory_mb"
        case enginePID = "engine_pid"
    }

    public init(
        modelLoaded: Bool,
        engineURL: String,
        daemonRssMb: Double,
        daemonPID: Int,
        suspendSupported: Bool,
        engineMemoryMb: Double? = nil,
        enginePID: Int? = nil
    ) {
        self.modelLoaded = modelLoaded
        self.engineURL = engineURL
        self.daemonRssMb = daemonRssMb
        self.daemonPID = daemonPID
        self.suspendSupported = suspendSupported
        self.engineMemoryMb = engineMemoryMb
        self.enginePID = enginePID
    }
}

public struct AnnounceRequest: Codable, Sendable, Equatable {
    public let sessionId: String
    public let label: String
    public let text: String

    enum CodingKeys: String, CodingKey {
        case label
        case text
        case sessionId = "session_id"
    }

    public init(sessionId: String, label: String, text: String) {
        self.sessionId = sessionId
        self.label = label
        self.text = text
    }
}

public struct AnnounceResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let id: String?

    public init(ok: Bool, id: String? = nil) {
        self.ok = ok
        self.id = id
    }
}

public struct HealthResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let version: String
    public let engineUp: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case version
        case engineUp = "engine_up"
    }

    public init(ok: Bool, version: String, engineUp: Bool) {
        self.ok = ok
        self.version = version
        self.engineUp = engineUp
    }
}

public enum PlayMode: String, Codable, Sendable {
    case full
    case summary
}

public struct PlayResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let reason: String?

    public init(ok: Bool, reason: String? = nil) {
        self.ok = ok
        self.reason = reason
    }
}

public enum DaemonError: Error, Sendable, Equatable {
    case empty
    case bothTextAndURL
    case neitherTextNorURL
    case engineDown
    case engineError(String)
    case engineTimeout
    case extractFailed
    case notFound
    case http(Int, String)
    case decode(String)
    case transport(String)
    case invalidURL(String)

    public static func == (lhs: DaemonError, rhs: DaemonError) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty),
            (.bothTextAndURL, .bothTextAndURL),
            (.neitherTextNorURL, .neitherTextNorURL),
            (.engineDown, .engineDown),
            (.engineTimeout, .engineTimeout),
            (.extractFailed, .extractFailed),
            (.notFound, .notFound):
            return true
        case (.engineError(let lhsMsg), .engineError(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.http(let codeA, let bodyA), .http(let codeB, let bodyB)):
            return codeA == codeB && bodyA == bodyB
        case (.decode(let lhsMsg), .decode(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.transport(let lhsMsg), .transport(let rhsMsg)):
            return lhsMsg == rhsMsg
        case (.invalidURL(let lhsURL), .invalidURL(let rhsURL)):
            return lhsURL == rhsURL
        default:
            return false
        }
    }
}
