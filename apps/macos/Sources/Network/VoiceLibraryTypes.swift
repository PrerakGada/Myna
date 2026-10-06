// VoiceLibraryTypes.swift — the wire types for the user's own voices.
//
// The daemon lists voices per engine (`GET /v2/voices`), but only some
// engines can take new ones: Pocket TTS and Chatterbox copy a voice from a
// short clip, Kokoro mixes its voices into blends, Soprano has one voice
// and nothing else. `VoicesEngineInfo` says which, so the Voices screen
// offers only what the engine can do. Contract: docs/native-app/API_CONTRACT.md.
import Foundation

/// What the active engine can do with voices.
public struct VoicesEngineInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let canClone: Bool
    public let canBlend: Bool
    /// Said instead of a picker when there is nothing to pick (Soprano).
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case canClone = "can_clone"
        case canBlend = "can_blend"
        case note
    }

    public init(id: String, name: String, canClone: Bool, canBlend: Bool, note: String? = nil) {
        self.id = id
        self.name = name
        self.canClone = canClone
        self.canBlend = canBlend
        self.note = note
    }
}

/// A ready-made clip from the voice library (Kyutai's tts-voices set).
public struct LibraryVoice: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let group: String
    public let gender: String?
    public let age: Int?
    public let detail: String
    public let license: String
    public let credit: String
    public let sizeKb: Int
    /// The user's voice id once added.
    public let addedAs: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case group
        case gender
        case age
        case detail
        case license
        case credit
        case sizeKb = "size_kb"
        case addedAs = "added_as"
    }
}

public struct VoiceLibraryResponse: Codable, Sendable, Equatable {
    public let voices: [LibraryVoice]
    public let source: String
}

public struct BlendPart: Codable, Sendable, Equatable {
    public let voice: String
    public let weight: Int

    public init(voice: String, weight: Int) {
        self.voice = voice
        self.weight = weight
    }
}

struct BlendRequest: Codable, Sendable {
    let name: String?
    let mix: [BlendPart]
}

struct RenameVoiceRequest: Codable, Sendable {
    let name: String
}

/// A refused voice action. The daemon's message is already written for
/// people ("The clip is 3.2 s. Use at least 5.5 seconds of speech."), so
/// it is shown as-is.
public struct VoiceActionError: Error, Sendable, Equatable, LocalizedError {
    public let reason: String
    public let message: String

    public var errorDescription: String? { message }

    /// FastAPI nests our payload under "detail": {"detail": {"reason", "detail"}}.
    static func from(status: Int, body: Data) -> VoiceActionError {
        struct Inner: Decodable { let reason: String?; let detail: String? }
        struct Outer: Decodable { let detail: Inner? }
        let inner = (try? JSONDecoder().decode(Outer.self, from: body))?.detail
        let reason = inner?.reason ?? "http_\(status)"
        let message: String
        switch reason {
        case "download_failed":
            message = "Couldn't download that voice. Check the internet connection and try again."
        case "not_found":
            message = "That voice no longer exists."
        default:
            message = inner?.detail ?? "The daemon answered \(status)."
        }
        return VoiceActionError(reason: reason, message: message)
    }
}

struct OkResponse: Codable, Sendable {
    let ok: Bool
}
