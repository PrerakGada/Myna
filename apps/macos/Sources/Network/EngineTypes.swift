// EngineTypes.swift — wire types for the daemon's voice-engine catalog
// (GET /v2/engines, POST /v2/engines/{id}/install|activate, DELETE).
//
// Mirrors daemon/myna/v2_types.py (V2Engine & friends). The stats block is
// what the Engine page shows on hover: numbers measured in the Phase 0
// bake-off (tools/engine-bakeoff), not live measurements.
import Foundation

public struct EngineStats: Codable, Sendable, Equatable {
    /// Seconds to synthesize Myna's first 15-word chunk — the wait before
    /// the first word.
    public let firstWordS: Double
    /// Seconds to the first streamed audio, for engines that stream.
    public let streamFirstS: Double?
    /// Seconds of audio produced per second of work.
    public let speedX: Double
    /// Peak memory while reading a ~1,300-character paragraph.
    public let peakMemoryMb: Double
    /// Words a speech-to-text check heard wrong, as a percentage.
    public let wordErrorPct: Double
    public let measuredOn: String

    enum CodingKeys: String, CodingKey {
        case firstWordS = "first_word_s"
        case streamFirstS = "stream_first_s"
        case speedX = "speed_x"
        case peakMemoryMb = "peak_memory_mb"
        case wordErrorPct = "word_error_pct"
        case measuredOn = "measured_on"
    }
}

public struct EngineVoice: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
}

public struct EngineEntry: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        case installed
        case downloading
        case failed
        case notInstalled = "not_installed"
    }

    public let id: String
    public let name: String
    public let maker: String
    public let tagline: String
    public let description: String
    public let repo: String
    public let params: String
    public let languages: [String]
    public let license: String
    public let credit: String?
    public let badge: String?
    public let downloadMb: Int
    public let sampleRate: Int
    public let nativeSpeed: Bool
    /// Speaks in any voice from a short recording (Pocket, Chatterbox).
    public let cloning: Bool
    /// Mixes its voices into new ones (Kokoro). Nil from older daemons.
    public let blending: Bool?
    public let voices: [EngineVoice]
    public let defaultVoice: String
    public let stats: EngineStats
    public let active: Bool
    public let state: State
    public let progress: Double?
    public let downloadedMb: Double?
    public let totalMb: Double?
    public let diskMb: Double?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case id, name, maker, tagline, description, repo, params, languages, license
        case credit, badge, voices, stats, active, state, progress, error, cloning, blending
        case downloadMb = "download_mb"
        case sampleRate = "sample_rate"
        case nativeSpeed = "native_speed"
        case defaultVoice = "default_voice"
        case downloadedMb = "downloaded_mb"
        case totalMb = "total_mb"
        case diskMb = "disk_mb"
    }

    public var isInstalled: Bool { state == .installed }
}

public struct EnginesResponse: Codable, Sendable, Equatable {
    public let active: String
    public let switchingTo: String?
    public let engines: [EngineEntry]

    enum CodingKeys: String, CodingKey {
        case active, engines
        case switchingTo = "switching_to"
    }
}

public struct EngineActivateResponse: Codable, Sendable, Equatable {
    public let ok: Bool
    public let active: String
    public let voice: String
    public let loadS: Double

    enum CodingKeys: String, CodingKey {
        case ok, active, voice
        case loadS = "load_s"
    }
}

/// A failed engine action, with the daemon's own explanation when it gave one.
public struct EngineActionError: Error, Sendable, Equatable, LocalizedError {
    public let reason: String
    public let message: String

    public var errorDescription: String? { message }

    /// FastAPI nests our payload under "detail": {"detail": {"reason", "detail"}}.
    static func from(status: Int, body: Data) -> EngineActionError {
        struct Inner: Decodable { let reason: String?; let detail: String? }
        struct Outer: Decodable { let detail: Inner? }
        let inner = (try? JSONDecoder().decode(Outer.self, from: body))?.detail
        let reason = inner?.reason ?? "http_\(status)"
        let message: String
        switch reason {
        case "not_installed": message = "Download this engine before switching to it."
        case "engine_down": message = "The voice engine isn't running. Restart it from Diagnostics."
        case "switch_in_progress": message = "Another engine is still loading."
        case "engine_active": message = inner?.detail ?? "Switch to another engine before removing this one."
        default: message = inner?.detail ?? "The daemon answered \(status)."
        }
        return EngineActionError(reason: reason, message: message)
    }
}
