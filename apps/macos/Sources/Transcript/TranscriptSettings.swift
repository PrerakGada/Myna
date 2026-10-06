// TranscriptSettings.swift — the Reading pane's "Show transcript while
// reading" choice. Stored as plain defaults so @AppStorage can bind to it and
// the store can read it on every read without holding a settings object.
import Foundation

public enum TranscriptVisibility: String, CaseIterable, Identifiable, Sendable {
    /// No transcript button anywhere, and the panel never opens.
    case off
    /// The pill and Dashboard show a transcript button; nothing opens by itself.
    case onRequest
    /// As `onRequest`, and the panel opens by itself for a long read.
    case automatic

    public static let defaultsKey = "dev.myna.app.transcriptVisibility"
    public static let defaultValue: TranscriptVisibility = .onRequest

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .onRequest: return "When I open it"
        case .automatic: return "Automatically for long reads"
        }
    }

    public static func current(_ defaults: UserDefaults = .standard) -> TranscriptVisibility {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

/// "Automatically for reads longer than N words": the N.
public enum TranscriptAutoOpen {
    public static let defaultsKey = "dev.myna.app.transcriptAutoOpenWords"
    public static let defaultWords = 200
    /// The choices the Reading pane offers.
    public static let choices = [100, 200, 500, 1_000]

    public static func words(_ defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: defaultsKey)
        return saved > 0 ? saved : defaultWords
    }

    /// Open the panel by itself for a read of `wordCount` words?
    public static func shouldOpen(
        wordCount: Int, visibility: TranscriptVisibility, threshold: Int
    ) -> Bool {
        visibility == .automatic && wordCount > threshold
    }
}
