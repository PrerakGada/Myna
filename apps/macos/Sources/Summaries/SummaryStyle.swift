// SummaryStyle.swift — what kind of summary the summary key makes, and which
// model makes it.
//
// Both choices live in the app's defaults under their own keys, read on every
// summary so a change in the Summaries card applies to the very next read.
// They're kept out of SettingsViewModel on purpose: several features add
// settings at once, and that shared file is where merges go wrong.
import Foundation

/// The four ways Myna can summarize. Raw values are the daemon's
/// `summary_style` values (daemon/myna/summarize.py STYLES).
public enum SummaryStyle: String, CaseIterable, Identifiable, Sendable, Codable {
    case tldr
    case keyPoints = "key_points"
    case actionItems = "action_items"
    case plainEnglish = "plain_english"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tldr: return "TL;DR"
        case .keyPoints: return "Key points"
        case .actionItems: return "Action items"
        case .plainEnglish: return "Plain English"
        }
    }

    /// One line for the picker's help text.
    public var help: String {
        switch self {
        case .tldr: return "Two or three sentences, most important fact first."
        case .keyPoints: return "Three to five points, read as “First… Second…”."
        case .actionItems: return "Only what the text asks you to do, with its deadlines and contacts."
        case .plainEnglish: return "The same text in simpler words, barely shorter."
        }
    }
}

/// Which model summarizes. Automatic tries Apple's on-device model first and
/// falls back to Ollama; the other two use only the one named.
public enum SummaryBackendChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case apple
    case ollama

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .apple: return "Apple Intelligence"
        case .ollama: return "Ollama"
        }
    }
}

/// The saved choices. `@AppStorage` in the card binds to the same keys.
public enum SummaryPreferences {
    public static let backendKey = "dev.myna.app.summaryBackend"
    public static let styleKey = "dev.myna.app.summaryStyle"

    public static let defaultBackend: SummaryBackendChoice = .automatic
    public static let defaultStyle: SummaryStyle = .tldr

    public static func backend(_ defaults: UserDefaults = .standard) -> SummaryBackendChoice {
        defaults.string(forKey: backendKey).flatMap(SummaryBackendChoice.init(rawValue:)) ?? defaultBackend
    }

    public static func style(_ defaults: UserDefaults = .standard) -> SummaryStyle {
        defaults.string(forKey: styleKey).flatMap(SummaryStyle.init(rawValue:)) ?? defaultStyle
    }
}
