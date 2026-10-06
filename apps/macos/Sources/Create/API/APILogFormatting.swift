// APILogFormatting.swift — turns the daemon's request log
// (`GET /v2/api/log`) into the strings the Recent requests table shows.
//
// Kept pure and separate from the view so the shortening rules (user
// agents especially, which are long and inconsistent) are unit-tested
// rather than eyeballed. The daemon never logs input text, only its
// length, and nothing here could show it.
import Foundation

struct APILogRow: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case clientError
        case serverError
    }

    let id: String
    let time: String
    let client: String
    /// True for requests from this Mac.
    let isLocal: Bool
    let agent: String
    let method: String
    let path: String
    let status: String
    let tone: Tone
    let duration: String
    let chars: String
    let audio: String

    init(_ entry: APIRequestLogEntry, id: String? = nil, timeZone: TimeZone = .current) {
        self.id = id ?? entry.id
        time = APILogFormat.time(entry.at, timeZone: timeZone)
        (client, isLocal) = APILogFormat.client(entry.client)
        agent = APILogFormat.userAgent(entry.userAgent)
        method = entry.method.uppercased()
        path = entry.path
        status = String(entry.status)
        tone = APILogFormat.tone(entry.status)
        duration = APILogFormat.duration(ms: entry.ms)
        chars = APILogFormat.chars(entry.chars)
        audio = APILogFormat.audio(entry.audioS)
    }

    /// Rows for a log page, with ids made unique even if two entries
    /// share a timestamp, method, path and client (SwiftUI's ForEach
    /// misbehaves on duplicate ids).
    static func rows(_ entries: [APIRequestLogEntry], timeZone: TimeZone = .current) -> [APILogRow] {
        var seen: [String: Int] = [:]
        return entries.map { entry in
            let count = seen[entry.id, default: 0]
            seen[entry.id] = count + 1
            let id = count == 0 ? entry.id : "\(entry.id)#\(count)"
            return APILogRow(entry, id: id, timeZone: timeZone)
        }
    }
}

enum APILogFormat {

    static let placeholder = "—"

    static func time(_ unix: Double, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: unix))
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Loopback reads as "This Mac"; anything else is the caller's address.
    static func client(_ raw: String) -> (label: String, isLocal: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let local: Set<String> = ["127.0.0.1", "::1", "localhost", "::ffff:127.0.0.1"]
        if local.contains(trimmed.lowercased()) { return ("This Mac", true) }
        return (trimmed.isEmpty ? placeholder : trimmed, false)
    }

    /// `OpenAI/Python 1.40.0` stays; `Myna/57 CFNetwork/1568 Darwin/25.0`
    /// becomes `Myna 57`; browsers collapse to their name. Anything longer
    /// than `maxAgentLength` is cut with an ellipsis.
    static func userAgent(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return placeholder }
        if raw.hasPrefix("Mozilla/") { return browserName(raw) }

        // Drop "(Macintosh; …)"-style comments, then look at product tokens.
        let stripped = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let tokens = stripped.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return placeholder }

        var label: String
        let halves = first.split(separator: "/", maxSplits: 1).map(String.init)
        if halves.count == 2, isVersion(halves[1]) {
            label = "\(halves[0]) \(halves[1])"
        } else {
            label = first
            if tokens.count > 1, isVersion(tokens[1]) { label += " \(tokens[1])" }
        }
        return truncate(label, to: maxAgentLength)
    }

    static let maxAgentLength = 28

    static func tone(_ status: Int) -> APILogRow.Tone {
        switch status {
        case ..<400: return .success
        case 400..<500: return .clientError
        default: return .serverError
        }
    }

    /// `412 ms`, `1.8 s`, `12 s`.
    static func duration(ms: Int) -> String {
        if ms < 1_000 { return "\(max(ms, 0)) ms" }
        let seconds = Double(ms) / 1_000
        return seconds < 10 ? String(format: "%.1f s", seconds) : "\(Int(seconds.rounded())) s"
    }

    static func chars(_ count: Int?) -> String {
        guard let count else { return placeholder }
        return count.formatted(.number.grouping(.automatic))
    }

    /// `4.2 s`, `1:05`, `1:02:03`.
    static func audio(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return placeholder }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - helpers

    private static func isVersion(_ value: String) -> Bool {
        guard let first = value.first, first.isNumber else { return false }
        return value.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter }
    }

    private static func browserName(_ raw: String) -> String {
        if raw.contains("Edg/") { return "Edge" }
        if raw.contains("Firefox/") { return "Firefox" }
        if raw.contains("Chrome/") { return "Chrome" }
        if raw.contains("Safari/") { return "Safari" }
        return "Browser"
    }

    private static func truncate(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}
