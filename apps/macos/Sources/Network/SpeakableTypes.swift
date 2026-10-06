// SpeakableTypes.swift — wire types for the daemon's text prep.
//
// The daemon cleans text before it speaks it (daemon/myna/speakable.py):
// markdown syntax, code, bare URLs and citation marks out, per a preset the
// read's source picks. Every read sends its source and a prep; History asks
// POST /v2/speakable to show a past read "as heard". Contract:
// docs/native-app/API_CONTRACT.md.
import Foundation

/// How the daemon prepares text before speaking it.
public enum TextPrep: String, Codable, Sendable, Equatable, CaseIterable {
    /// Clean it up with the preset for the read's source.
    case auto
    /// Read it exactly as written.
    case literal

    /// Tolerant decode: an unknown value from a newer daemon reads as `auto`.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TextPrep(rawValue: raw) ?? .auto
    }
}

/// `POST /v2/speakable` body.
public struct SpeakableRequest: Codable, Sendable, Equatable {
    public var text: String
    public var source: String?
    public var prep: TextPrep
    /// A document's kind (web, pdf, epub…); web/pdf/epub get the article rules.
    public var sourceKind: String?

    public init(text: String, source: String? = nil, prep: TextPrep = .auto, sourceKind: String? = nil) {
        self.text = text
        self.source = source
        self.prep = prep
        self.sourceKind = sourceKind
    }

    enum CodingKeys: String, CodingKey {
        case text, source, prep
        case sourceKind = "source_kind"
    }
}

/// `POST /v2/speakable` answer: the words a read would speak.
public struct SpeakableResponse: Codable, Sendable, Equatable {
    public let text: String
    /// False when cleanup changed nothing a listener could hear.
    public let changed: Bool
    /// base | claude_code | article | literal
    public let preset: String

    public init(text: String, changed: Bool, preset: String) {
        self.text = text
        self.changed = changed
        self.preset = preset
    }
}
