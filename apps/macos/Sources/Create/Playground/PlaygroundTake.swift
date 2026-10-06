// PlaygroundTake.swift — one rendered clip and how the list groups them.
//
// A take is the unit the Playground keeps: the exact text, the voice and
// speed it was spoken with, what the daemon reported about the render,
// and a strip of waveform peaks so the list can draw it without reading
// the audio back. The audio itself is a WAV next to the index, named by
// the take's id.
import Foundation

struct PlaygroundTake: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    /// Exactly what was sent. Empty for a take recovered from a WAV whose
    /// index entry was lost.
    let text: String
    /// Voice id the daemon actually used (its `X-Myna-Voice` header).
    let voice: String
    let voiceLabel: String
    let engine: String?
    /// Nil when the engine speaks at a fixed pace and ignored speed.
    let speed: Double?
    let durationS: Double
    let renderMs: Int?
    /// Waveform peaks, 0…255. See `PlaygroundWaveformMath.quantize`.
    let bars: [UInt8]
    /// Takes made by one "Compare" share this id.
    let groupId: String?
    /// True for a take rebuilt from its audio after the index was lost.
    let recovered: Bool?

    init(
        id: String = PlaygroundTake.newId(),
        createdAt: Date = Date(),
        text: String,
        voice: String,
        voiceLabel: String,
        engine: String?,
        speed: Double?,
        durationS: Double,
        renderMs: Int?,
        bars: [UInt8],
        groupId: String? = nil,
        recovered: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.voice = voice
        self.voiceLabel = voiceLabel
        self.engine = engine
        self.speed = speed
        self.durationS = durationS
        self.renderMs = renderMs
        self.bars = bars
        self.groupId = groupId
        self.recovered = recovered
    }

    enum CodingKeys: String, CodingKey {
        case id, text, voice, engine, speed, bars, recovered
        case createdAt = "created_at"
        case voiceLabel = "voice_label"
        case durationS = "duration_s"
        case renderMs = "render_ms"
        case groupId = "group_id"
    }

    static func newId() -> String {
        "t_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    var fileName: String { "\(id).wav" }

    var peaks: [Float] { PlaygroundWaveformMath.dequantize(bars) }

    var isRecovered: Bool { recovered == true }

    /// One line for the list: whitespace collapsed, cut at `limit`.
    func snippet(limit: Int = 110) -> String {
        guard !text.isEmpty else { return isRecovered ? "Recovered take (text unknown)" : "Untitled take" }
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// How the takes list lays out: a single take is a row; the takes of one
/// comparison sit side by side in one card, left to right in the order
/// they were rendered.
enum PlaygroundTakeSection: Identifiable, Equatable, Sendable {
    case single(PlaygroundTake)
    case comparison(id: String, takes: [PlaygroundTake])

    var id: String {
        switch self {
        case .single(let take): return take.id
        case .comparison(let id, _): return "group-\(id)"
        }
    }

    /// `takes` is newest first; the sections keep that order, each
    /// comparison placed where its newest take would have been. A
    /// comparison with only one take left is shown as a plain row.
    static func sections(from takes: [PlaygroundTake]) -> [PlaygroundTakeSection] {
        var byGroup: [String: [PlaygroundTake]] = [:]
        for take in takes {
            if let group = take.groupId { byGroup[group, default: []].append(take) }
        }
        var emitted = Set<String>()
        var sections: [PlaygroundTakeSection] = []
        for take in takes {
            guard let group = take.groupId, let members = byGroup[group], members.count > 1 else {
                sections.append(.single(take))
                continue
            }
            guard emitted.insert(group).inserted else { continue }
            let ordered = members.sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
            }
            sections.append(.comparison(id: group, takes: ordered))
        }
        return sections
    }
}
