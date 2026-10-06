// DashboardPane.swift — the Dashboard's navigation model.
//
// One enum, used by the sidebar, the window's deep-link API and the
// `myna://dashboard?pane=…` URL route, so there is exactly one list of
// places the window can be and no way for them to drift apart.
import Foundation

public enum DashboardPane: String, CaseIterable, Identifiable, Sendable, Equatable {
    case overview
    case history
    case playground
    case studio
    case api
    case voices
    case pronunciation
    case shortcuts
    case reading
    case gestures
    case wardrobe
    case daemon
    case logs
    case account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .history: return "History"
        case .playground: return "Playground"
        case .studio: return "Studio"
        case .api: return "API"
        case .voices: return "Voices"
        case .pronunciation: return "Pronunciation"
        case .shortcuts: return "Shortcuts"
        case .reading: return "Reading"
        case .gestures: return "Gestures"
        case .wardrobe: return "App Voices"
        case .daemon: return "Engine"
        case .logs: return "Logs"
        case .account: return "Account & Data"
        }
    }

    public var systemImage: String {
        switch self {
        case .overview: return "chart.bar.xaxis"
        case .history: return "clock.arrow.circlepath"
        case .playground: return "text.bubble"
        case .studio: return "tray.and.arrow.down"
        case .api: return "chevron.left.forwardslash.chevron.right"
        case .voices: return "waveform"
        case .pronunciation: return "character.bubble"
        case .shortcuts: return "keyboard"
        case .reading: return "text.book.closed"
        case .gestures: return "hand.tap"
        case .wardrobe: return "person.crop.rectangle.stack"
        case .daemon: return "server.rack"
        case .logs: return "doc.text.magnifyingglass"
        case .account: return "person.crop.circle"
        }
    }

    /// One-line description shown under the pane title.
    public var subtitle: String {
        switch self {
        case .overview: return "What Myna has read for you, and how much of it you heard."
        case .history: return "Every read, searchable. Click any row to hear it again."
        case .playground: return "Type anything and hear it. Tune the voice, then save the take."
        case .studio: return "Turn articles, documents and books into audio files you keep."
        case .api: return "Use Myna's voice from any app, script or tool on this Mac."
        case .voices: return "Preview and choose the voice Myna speaks in."
        case .pronunciation: return "Teach Myna how to say the words it gets wrong."
        case .shortcuts: return "The global chords that trigger Myna from any app."
        case .reading: return "How Myna speaks, and what it does when Claude Code finishes."
        case .gestures: return "Trackpad gestures, for reading without reaching for a chord."
        case .wardrobe: return "Give an app its own voice. The frontmost app wins."
        case .daemon: return "Pick the voice model Myna speaks with. Everything runs on this Mac."
        case .logs: return "Live tail of what Myna is doing."
        case .account: return "Where your data lives, and what leaves this Mac."
        }
    }

    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case insights
        case create
        case voice
        case controls
        case system

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .insights: return "Insights"
            case .create: return "Create"
            case .voice: return "Voice"
            case .controls: return "Controls"
            case .system: return "System"
            }
        }

        public var panes: [DashboardPane] {
            switch self {
            case .insights: return [.overview, .history]
            case .create: return [.playground, .studio, .api]
            case .voice: return [.voices, .pronunciation, .wardrobe]
            case .controls: return [.shortcuts, .reading, .gestures]
            case .system: return [.daemon, .logs, .account]
            }
        }
    }

    /// Parse a `pane=` query value. Tolerant of case and of a couple of
    /// obvious aliases so the URL route is forgiving.
    public static func parse(_ raw: String?) -> DashboardPane? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        if let exact = DashboardPane(rawValue: raw) { return exact }
        switch raw {
        case "stats", "analytics", "dashboard", "home": return .overview
        case "recents", "recent": return .history
        case "tts", "try", "sandbox": return .playground
        case "convert", "export", "exports", "library", "renders", "audiobook": return .studio
        case "developer", "server", "openai", "http": return .api
        case "settings", "preferences", "hotkeys", "keys": return .shortcuts
        case "voice": return .voices
        case "pronunciations", "dictionary", "lexicon", "words": return .pronunciation
        case "engine", "model": return .daemon
        case "log": return .logs
        case "data", "privacy": return .account
        default: return nil
        }
    }
}
