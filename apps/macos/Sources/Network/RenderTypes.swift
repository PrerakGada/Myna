// RenderTypes.swift — wire types for the render API: finished audio files
// out of the daemon (POST /v1/audio/speech, /v2/renders jobs, /v2/formats,
// /v2/transcode, /v2/api/*).
//
// The contract is docs/native-app/RENDER_API.md. Change both together.
import Foundation

// MARK: - formats

public struct AudioFormatInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let available: Bool
    public let ext: String
    public let mime: String
    /// Why an unavailable format can't be produced ("needs ffmpeg or lame").
    public let reason: String?
}

public struct AudioFormatsResponse: Codable, Sendable, Equatable {
    public let formats: [AudioFormatInfo]
}

// MARK: - POST /v1/audio/speech

public struct SpeechRequest: Codable, Sendable, Equatable {
    public var input: String
    public var model: String?
    public var voice: String?
    /// `mp3 opus aac flac wav pcm m4a`. The app almost always wants `wav`
    /// and transcodes on save, so a take is synthesized exactly once.
    public var responseFormat: String
    public var speed: Double?
    /// Myna's own field: `.literal` reads the input as written; nil or
    /// `.auto` cleans markdown, code and URLs out first.
    public var mynaPrep: TextPrep?

    public init(
        input: String,
        model: String? = nil,
        voice: String? = nil,
        responseFormat: String = "wav",
        speed: Double? = nil,
        mynaPrep: TextPrep? = nil
    ) {
        self.input = input
        self.model = model
        self.voice = voice
        self.responseFormat = responseFormat
        self.speed = speed
        self.mynaPrep = mynaPrep
    }

    enum CodingKeys: String, CodingKey {
        case input, model, voice, speed
        case responseFormat = "response_format"
        case mynaPrep = "myna_prep"
    }
}

/// A finished take, plus what the daemon says it made.
public struct SpeechResult: Sendable, Equatable {
    public let audio: Data
    public let contentType: String
    public let engine: String?
    public let voice: String?
    public let durationS: Double?
    public let sampleRate: Int?
    public let chunks: Int?
    public let renderMs: Int?

    public init(
        audio: Data,
        contentType: String,
        engine: String? = nil,
        voice: String? = nil,
        durationS: Double? = nil,
        sampleRate: Int? = nil,
        chunks: Int? = nil,
        renderMs: Int? = nil
    ) {
        self.audio = audio
        self.contentType = contentType
        self.engine = engine
        self.voice = voice
        self.durationS = durationS
        self.sampleRate = sampleRate
        self.chunks = chunks
        self.renderMs = renderMs
    }
}

// MARK: - /v2/renders

public struct RenderSection: Codable, Sendable, Equatable {
    public var title: String
    public var text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public struct RenderRequest: Codable, Sendable, Equatable {
    public var title: String?
    public var text: String?
    public var url: String?
    public var sections: [RenderSection]?
    public var voice: String?
    public var speed: Double?
    public var format: String
    public var source: String
    public var sectionPauseMs: Int?
    /// `.literal` renders the text as written; nil = the daemon's `.auto`.
    public var prep: TextPrep?
    /// The document's kind (web, pdf, epub, markdown…). web/pdf/epub get
    /// the article cleanup: captions, ads and reference lists out.
    public var sourceKind: String?

    public init(
        title: String? = nil,
        text: String? = nil,
        url: String? = nil,
        sections: [RenderSection]? = nil,
        voice: String? = nil,
        speed: Double? = nil,
        format: String = "m4a",
        source: String = "studio",
        sectionPauseMs: Int? = nil,
        prep: TextPrep? = nil,
        sourceKind: String? = nil
    ) {
        self.title = title
        self.text = text
        self.url = url
        self.sections = sections
        self.voice = voice
        self.speed = speed
        self.format = format
        self.source = source
        self.sectionPauseMs = sectionPauseMs
        self.prep = prep
        self.sourceKind = sourceKind
    }

    enum CodingKeys: String, CodingKey {
        case title, text, url, sections, voice, speed, format, source, prep
        case sectionPauseMs = "section_pause_ms"
        case sourceKind = "source_kind"
    }
}

public struct RenderChapter: Codable, Sendable, Equatable {
    public let title: String
    public let startS: Double

    enum CodingKeys: String, CodingKey {
        case title
        case startS = "start_s"
    }
}

public struct RenderError: Codable, Sendable, Equatable {
    public let reason: String
    public let detail: String?
}

public struct RenderJob: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case queued, rendering, encoding, done, failed, cancelled

        public var isActive: Bool { self == .queued || self == .rendering || self == .encoding }
    }

    public let id: String
    public let title: String
    public let status: Status
    public let source: String
    public let createdAt: Double
    public let startedAt: Double?
    public let finishedAt: Double?
    public let engine: String
    public let voice: String
    public let speed: Double
    public let format: String
    public let chars: Int
    public let words: Int
    public let chunksTotal: Int
    public let chunksDone: Int
    public let progress: Double
    public let audioS: Double
    public let etaS: Double?
    public let filePath: String?
    public let bytes: Int?
    public let chapters: [RenderChapter]?
    public let error: RenderError?
    public let preview: String?

    public var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }

    enum CodingKeys: String, CodingKey {
        case id, title, status, source, engine, voice, speed, format, chars, words
        case progress, bytes, chapters, error, preview
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case chunksTotal = "chunks_total"
        case chunksDone = "chunks_done"
        case audioS = "audio_s"
        case etaS = "eta_s"
        case filePath = "file_path"
    }
}

public struct RenderListResponse: Codable, Sendable, Equatable {
    public let renders: [RenderJob]
}

// MARK: - /v2/api/*

public struct APISettings: Codable, Sendable, Equatable {
    public let baseUrl: String
    public let lanEnabled: Bool
    public let lanUrls: [String]
    public let apiKey: String?
    public let requiresKeyOnLan: Bool
    public let restartPending: Bool

    enum CodingKeys: String, CodingKey {
        case baseUrl = "base_url"
        case lanEnabled = "lan_enabled"
        case lanUrls = "lan_urls"
        case apiKey = "api_key"
        case requiresKeyOnLan = "requires_key_on_lan"
        case restartPending = "restart_pending"
    }
}

public struct APISettingsUpdate: Codable, Sendable, Equatable {
    public var lanEnabled: Bool?
    public var regenerateKey: Bool?

    public init(lanEnabled: Bool? = nil, regenerateKey: Bool? = nil) {
        self.lanEnabled = lanEnabled
        self.regenerateKey = regenerateKey
    }

    enum CodingKeys: String, CodingKey {
        case lanEnabled = "lan_enabled"
        case regenerateKey = "regenerate_key"
    }
}

public struct APIRequestLogEntry: Codable, Sendable, Equatable, Identifiable {
    public let at: Double
    public let method: String
    public let path: String
    public let client: String
    public let userAgent: String?
    public let status: Int
    public let ms: Int
    public let chars: Int?
    public let format: String?
    public let voice: String?
    public let audioS: Double?

    public var id: String { "\(at)-\(method)-\(path)-\(client)" }

    enum CodingKeys: String, CodingKey {
        case at, method, path, client, status, ms, chars, format, voice
        case userAgent = "user_agent"
        case audioS = "audio_s"
    }
}

public struct APIRequestLogResponse: Codable, Sendable, Equatable {
    public let requests: [APIRequestLogEntry]
}

// MARK: - errors

/// Errors from the render API. `/v1/*` answers in OpenAI's shape
/// (`{"error": {"code": …, "message": …}}`), `/v2/*` in the daemon's
/// (`{"ok": false, "reason": …, "detail": …}`); both land here.
public enum RenderAPIError: Error, Sendable, Equatable, LocalizedError {
    case emptyInput
    case inputTooLong
    case engineNotActive(String)
    case formatUnavailable(String)
    case engineDown
    case engineError(String)
    case notReady
    case notFound
    case http(Int, code: String?, message: String)
    case transport(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "There's no text to speak."
        case .inputTooLong: return "That's too long for a single clip. Send it to Studio instead."
        case .engineNotActive(let msg): return msg.isEmpty ? "That engine isn't the active one." : msg
        case .formatUnavailable(let msg): return msg.isEmpty ? "This Mac can't encode that format." : msg
        case .engineDown: return "The voice engine isn't running."
        case .engineError(let msg): return msg.isEmpty ? "The voice engine failed." : "The voice engine failed: \(msg)"
        case .notReady: return "That render hasn't finished yet."
        case .notFound: return "Not found."
        case .http(let status, _, let message): return message.isEmpty ? "HTTP \(status)" : message
        case .transport(let msg): return "Can't reach Myna's voice service: \(msg)"
        case .decode(let msg): return "Unexpected reply from Myna's voice service: \(msg)"
        }
    }
}
