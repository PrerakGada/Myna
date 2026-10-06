// DaemonClient+Summaries.swift — the summary calls (daemon/myna/summary_routes.py).
//
// An extension in its own file because DaemonClient's body is at the lint
// limit; makeRequest and decode are internal (not private) for this.
import Foundation

extension DaemonClient: SummaryDaemonAPI {
    /// Ollama may have to load the model before it answers, and a long text
    /// is summarized in parts inside the daemon's 180 s budget.
    public static let summarizeTimeout: TimeInterval = 200

    // MARK: - POST /v2/summarize with a style

    public func summarize(text: String, style: String?) async throws -> SummarizeResponse {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DaemonError.empty }
        var req = try makeRequest(
            path: "/v2/summarize", method: "POST", body: SummarizeRequest(text: text, summaryStyle: style))
        req.timeoutInterval = Self.summarizeTimeout
        return try await decode(req)
    }

    // MARK: - GET /v2/summarize/status

    /// Whether the daemon's Ollama fallback can summarize right now.
    public func summaryStatus() async throws -> SummaryStatusResponse {
        var req = try makeRequest(path: "/v2/summarize/status", method: "GET")
        req.timeoutInterval = 5
        return try await decode(req)
    }
}
