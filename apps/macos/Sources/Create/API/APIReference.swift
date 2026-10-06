// APIReference.swift — the reference tables at the bottom of the API
// pane: the HTTP endpoints, the `myna://` routes and the `myna` CLI.
//
// Data only. Each route and command below was read from the code that
// implements it (URLSchemeHandler.parse, cli/myna), and APIPaneTests
// checks every route still parses and every CLI flag still exists, so
// this list can't quietly promise something the app no longer does.
import Foundation

enum APIReference {

    // swiftlint:disable:next force_unwrapping
    static let docsURL = URL(string: "https://github.com/PrerakGada/myna/blob/main/docs/native-app/RENDER_API.md")!

    struct Endpoint: Identifiable, Sendable {
        let method: String
        let path: String
        let summary: String
        let params: String?
        var id: String { "\(method) \(path)" }
        /// `/v1/*` is the only thing other devices may reach.
        var lanReachable: Bool { path.hasPrefix("/v1/") }
    }

    static let endpoints: [Endpoint] = [
        Endpoint(
            method: "POST", path: "/v1/audio/speech",
            summary: "Text in, audio out. OpenAI's speech endpoint, up to 40,000 characters.",
            params: "input · voice · response_format · speed · model"),
        Endpoint(
            method: "GET", path: "/v1/models",
            summary: "The installed engines, plus tts-1, tts-1-hd and myna as names for the active one.",
            params: nil),
        Endpoint(
            method: "GET", path: "/v1/audio/voices",
            summary: "The active engine's voices, and the voice each OpenAI name maps to.",
            params: nil),
        Endpoint(
            method: "POST", path: "/v2/renders",
            summary: "Start a render job for anything long. Returns the job straight away.",
            params: "text | url | sections · voice · format · title"),
        Endpoint(
            method: "GET", path: "/v2/renders",
            summary: "Every render job, newest first.",
            params: nil),
        Endpoint(
            method: "GET", path: "/v2/renders/{id}",
            summary: "One job: progress, time left, and the file path once it's done.",
            params: nil),
        Endpoint(
            method: "GET", path: "/v2/renders/{id}/audio",
            summary: "The finished file.",
            params: nil),
        Endpoint(
            method: "POST", path: "/v2/renders/{id}/cancel",
            summary: "Stop a job and discard its partial audio.",
            params: nil),
        Endpoint(
            method: "DELETE", path: "/v2/renders/{id}",
            summary: "Remove a job and its file.",
            params: nil),
    ]

    struct Entry: Identifiable, Sendable {
        let value: String
        let summary: String
        var id: String { value }
    }

    /// Every route URLSchemeHandler.parse accepts.
    static let urlRoutes: [Entry] = [
        Entry(value: "myna://speak-selection", summary: "Read the text selected in the front app."),
        Entry(
            value: "myna://speak-selection?mode=summary",
            summary: "Read a summary of the selection instead (Apple Intelligence or Ollama)."),
        Entry(value: "myna://read-chrome", summary: "Read the article in Chrome's front tab."),
        Entry(value: "myna://toggle-pause", summary: "Pause, or resume."),
        Entry(value: "myna://stop", summary: "Stop reading."),
        Entry(value: "myna://seek?delta=15", summary: "Jump 15 seconds ahead. A negative number goes back."),
        Entry(value: "myna://speed?value=1.25", summary: "Set the speed, from 0.5 to 2."),
        Entry(value: "myna://speed?delta=0.25", summary: "Change the speed by a step. Negative slows down."),
        Entry(value: "myna://dashboard?pane=api", summary: "Open this window at a page: history, playground, studio, api…"),
    ]

    /// Every form cli/myna understands.
    static let cliCommands: [Entry] = [
        Entry(value: "myna \"Build finished\"", summary: "Speak text."),
        Entry(value: "pbpaste | myna", summary: "Speak whatever is piped in."),
        Entry(value: "myna --speed 1.25 \"Build finished\"", summary: "Speak at a set speed."),
        Entry(value: "pbpaste | myna --summary", summary: "Speak a short summary (needs Ollama)."),
        Entry(value: "myna doctor", summary: "Check that the voice service and the engine are up."),
    ]

    /// Where `myna` is installed on this Mac, if anywhere. Homebrew and the
    /// repo's install.sh put it on the PATH; the downloadable app doesn't.
    static func installedCLI(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        let candidates = [
            "/opt/homebrew/bin/myna",
            "/usr/local/bin/myna",
            "\(home)/.local/bin/myna",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
