// ReadEvent.swift — one record per thing Myna read aloud.
//
// This is the unit the whole Dashboard is built on. Before v0.6 the only
// history Myna kept was `RecentItemsStore`: a five-slot ring in
// UserDefaults holding title + voice + timestamp. Nothing measured how
// long a read actually was, whether it finished, where the text came
// from, or whether synthesis failed — so there was no data to analyse
// and "analytics" could not exist.
//
// A ReadEvent is written the moment a read starts (outcome == .reading)
// and mutated in place as the read progresses: first-audio latency when
// the first chunk lands, then listened seconds + a terminal outcome when
// the player returns to idle. That means a row is visible in the
// Dashboard while it is still playing, which is what you want on a
// second monitor.
//
// Codable with explicit defaults on every field added after the first
// release — a decode failure would throw away the user's entire history,
// so every optional stays optional forever.
import Foundation

/// Where the text came from. Drives the "Sources" breakdown and the
/// per-row icon in the History pane.
public enum ReadSource: String, Codable, Sendable, CaseIterable, Equatable {
    /// Selected text captured with ⌘C by the speak-selection hotkey/gesture.
    case selection
    /// An article extracted from the front Chrome tab.
    case article
    /// Text read straight off the clipboard from the popover, which cannot
    /// capture a selection (opening it makes Myna frontmost).
    case clipboard
    /// A Claude Code session reply played from the registry.
    case claudeCode = "claude_code"
    /// A row replayed from Recent / History.
    case replay
    /// The first-run cinematic's spoken intro.
    case onboarding
    /// A voice sample played from Settings.
    case preview
    /// Recorded before the source was known, or by an older build.
    case unknown

    public var label: String {
        switch self {
        case .selection: return "Selection"
        case .article: return "Article"
        case .clipboard: return "Clipboard"
        case .claudeCode: return "Claude Code"
        case .replay: return "Replay"
        case .onboarding: return "Onboarding"
        case .preview: return "Preview"
        case .unknown: return "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .selection: return "text.cursor"
        case .article: return "doc.richtext"
        case .clipboard: return "doc.on.clipboard"
        case .claudeCode: return "terminal"
        case .replay: return "arrow.counterclockwise"
        case .onboarding: return "sparkles"
        case .preview: return "waveform.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Tolerant decode — an unknown string from a newer build degrades to
    /// `.unknown` instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReadSource(rawValue: raw) ?? .unknown
    }
}

/// How a read ended. `.reading` is the live state; everything else is
/// terminal.
public enum ReadOutcome: String, Codable, Sendable, CaseIterable, Equatable {
    /// Still in flight (synthesizing or playing).
    case reading
    /// Played through to the end of the audio.
    case completed
    /// The user hit stop, or a newer read superseded this one.
    case stopped
    /// Synthesis or playback errored out. `errorMessage` says why.
    case failed

    public var label: String {
        switch self {
        case .reading: return "Reading"
        case .completed: return "Completed"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    public var isTerminal: Bool { self != .reading }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReadOutcome(rawValue: raw) ?? .stopped
    }
}

/// A single read, from hotkey press to silence.
public struct ReadEvent: Codable, Sendable, Identifiable, Equatable {

    // MARK: identity + timing

    public let id: String
    /// Unix ms when the read was requested (hotkey press), not when audio began.
    public let startedAtMs: Int
    /// Unix ms when the read reached a terminal outcome. nil while reading.
    public var endedAtMs: Int?

    // MARK: content

    /// Short display title — article host, or the head of the selection.
    public var title: String
    /// The text that was read, capped at `maxStoredText`. Kept so History
    /// rows replay the real text rather than re-reading their own title,
    /// and so the user can copy it back out. nil for article reads, which
    /// replay from `url`.
    public var text: String?
    /// Source URL for article reads.
    public var url: String?

    // MARK: how it was read

    public var source: ReadSource
    /// "full" or "summary" — matches SynthesizeMode.rawValue.
    public var mode: String
    public var voice: String
    public var speed: Double
    /// The text prep the read was sent with ("auto" or "literal"), so the
    /// History pane can show it "as heard" by asking the daemon again. nil
    /// for reads from before the daemon cleaned text: those were read as
    /// written.
    public var prep: String?

    // MARK: measurements

    /// Characters handed to the daemon.
    public var characters: Int
    /// Whitespace-separated word count. Drives "words read" and the
    /// reading-time-vs-listening-time comparison.
    public var words: Int
    /// Wall-clock ms from request to the first decoded audio chunk. The
    /// single number that tells you whether the engine is healthy.
    public var firstAudioMs: Int?
    /// Total decoded audio produced, in seconds at 1× speed.
    public var audioSeconds: Double
    /// Seconds of that audio the user actually heard. Less than
    /// `audioSeconds` for a stopped read.
    public var listenedSeconds: Double

    // MARK: context

    /// Bundle id of the app that was frontmost when the read was triggered.
    public var appBundleId: String?
    /// Human-readable name for that app, resolved at capture time.
    public var appName: String?
    /// Language the daemon's detector reported, when it disagreed with the voice.
    public var detectedLang: String?

    // MARK: outcome

    public var outcome: ReadOutcome
    public var errorMessage: String?

    /// Text longer than this is truncated before storage. Matches
    /// RecentItem.maxStoredText so a History replay behaves like a Recent
    /// replay.
    public static let maxStoredText = 20_000

    public init(
        id: String = UUID().uuidString,
        startedAtMs: Int = ReadEvent.currentTimeMs(),
        endedAtMs: Int? = nil,
        title: String,
        text: String? = nil,
        url: String? = nil,
        source: ReadSource = .unknown,
        mode: String = "full",
        voice: String,
        speed: Double = 1.0,
        prep: String? = nil,
        characters: Int = 0,
        words: Int = 0,
        firstAudioMs: Int? = nil,
        audioSeconds: Double = 0,
        listenedSeconds: Double = 0,
        appBundleId: String? = nil,
        appName: String? = nil,
        detectedLang: String? = nil,
        outcome: ReadOutcome = .reading,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.title = title
        self.text = text.map { String($0.prefix(ReadEvent.maxStoredText)) }
        self.url = url
        self.source = source
        self.mode = mode
        self.voice = voice
        self.speed = speed
        self.prep = prep
        self.characters = characters
        self.words = words
        self.firstAudioMs = firstAudioMs
        self.audioSeconds = audioSeconds
        self.listenedSeconds = listenedSeconds
        self.appBundleId = appBundleId
        self.appName = appName
        self.detectedLang = detectedLang
        self.outcome = outcome
        self.errorMessage = errorMessage
    }

    // MARK: - derived

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(startedAtMs) / 1000)
    }

    public var endedAt: Date? {
        endedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// Wall-clock seconds the read occupied, request to silence.
    public var elapsedSeconds: Double? {
        guard let endedAtMs else { return nil }
        return max(0, Double(endedAtMs - startedAtMs) / 1000)
    }

    /// Fraction of the produced audio the user heard, 0…1. nil when we
    /// never learned how long the audio was (a failure before any chunk).
    public var completionFraction: Double? {
        guard audioSeconds > 0 else { return nil }
        return min(1, max(0, listenedSeconds / audioSeconds))
    }

    /// How long this would have taken to read with your eyes, at the
    /// widely-cited 238 wpm silent-reading average for adult English prose
    /// (Brysbaert 2019). Used only for the "vs. reading it yourself"
    /// comparison, which is explicitly labelled as an estimate in the UI.
    public static let silentReadingWPM: Double = 238

    public var estimatedSilentReadingSeconds: Double {
        guard words > 0 else { return 0 }
        return Double(words) / ReadEvent.silentReadingWPM * 60
    }

    /// Display title, truncated for narrow rows.
    public func truncatedTitle(maxLength: Int = 64) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let flattened = trimmed.replacingOccurrences(of: "\n", with: " ")
        if flattened.count <= maxLength { return flattened }
        return String(flattened.prefix(maxLength)) + "…"
    }

    public static func currentTimeMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    /// Word count used consistently everywhere (store, analytics, tests).
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Codable
    //
    // Explicit keys so the on-disk format is stable and greppable, and so
    // renaming a Swift property can never silently orphan a user's
    // history. Every field added after v0.6 must decode with a default.

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case title
        case text
        case url
        case source
        case mode
        case voice
        case speed
        case prep
        case characters
        case words
        case firstAudioMs = "first_audio_ms"
        case audioSeconds = "audio_seconds"
        case listenedSeconds = "listened_seconds"
        case appBundleId = "app_bundle_id"
        case appName = "app_name"
        case detectedLang = "detected_lang"
        case outcome
        case errorMessage = "error_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        startedAtMs = try c.decodeIfPresent(Int.self, forKey: .startedAtMs) ?? 0
        endedAtMs = try c.decodeIfPresent(Int.self, forKey: .endedAtMs)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "(untitled)"
        text = try c.decodeIfPresent(String.self, forKey: .text)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        source = try c.decodeIfPresent(ReadSource.self, forKey: .source) ?? .unknown
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "full"
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? "—"
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        prep = try c.decodeIfPresent(String.self, forKey: .prep)
        characters = try c.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        firstAudioMs = try c.decodeIfPresent(Int.self, forKey: .firstAudioMs)
        audioSeconds = try c.decodeIfPresent(Double.self, forKey: .audioSeconds) ?? 0
        listenedSeconds = try c.decodeIfPresent(Double.self, forKey: .listenedSeconds) ?? 0
        appBundleId = try c.decodeIfPresent(String.self, forKey: .appBundleId)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        detectedLang = try c.decodeIfPresent(String.self, forKey: .detectedLang)
        outcome = try c.decodeIfPresent(ReadOutcome.self, forKey: .outcome) ?? .stopped
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
