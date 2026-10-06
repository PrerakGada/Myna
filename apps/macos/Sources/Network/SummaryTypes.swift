// SummaryTypes.swift — GET /v2/summarize/status (daemon/myna/summary_routes.py).
//
// Its own file so DaemonTypes.swift only grows the two `summary_style` fields.
import Foundation

public struct SummaryStatusResponse: Codable, Sendable, Equatable {
    public struct Ollama: Codable, Sendable, Equatable {
        /// "ready" | "model_missing" | "not_running" | "not_installed"
        public let state: String
        public let model: String
        public let url: String

        public init(state: String, model: String, url: String) {
            self.state = state
            self.model = model
            self.url = url
        }
    }

    public let ok: Bool
    public let ollama: Ollama
    public let styles: [String]
    public let defaultStyle: String

    enum CodingKeys: String, CodingKey {
        case ok
        case ollama
        case styles
        case defaultStyle = "default_style"
    }

    public init(ok: Bool = true, ollama: Ollama, styles: [String], defaultStyle: String) {
        self.ok = ok
        self.ollama = ollama
        self.styles = styles
        self.defaultStyle = defaultStyle
    }
}
