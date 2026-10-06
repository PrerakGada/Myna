// PronunciationClient.swift — the daemon's pronunciation list
// (/v2/pronunciations): word or phrase → respelling, applied after text
// cleanup on every read and render. The daemon owns the list and every
// answer is the whole list, so callers replace, never merge.
//
// Its own small actor rather than more DaemonClient methods: same shape
// (injectable URLSession), and DaemonClient is at its file-length limit.
// Contract: docs/api-contracts-daemon.md § 7.
import Foundation

public struct PronunciationEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let word: String
    public let say: String
    public let enabled: Bool
}

public struct StarterPronunciation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let word: String
    public let say: String
    /// What the engine said before the fix, roughly spelled out.
    public let heard: String?
    public let enabled: Bool
    /// The user has their own entry for this word, which wins.
    public let overridden: Bool
}

public struct PronunciationList: Codable, Sendable, Equatable {
    public let starterEnabled: Bool
    public let entries: [PronunciationEntry]
    public let starter: [StarterPronunciation]

    public init(starterEnabled: Bool, entries: [PronunciationEntry], starter: [StarterPronunciation]) {
        self.starterEnabled = starterEnabled
        self.entries = entries
        self.starter = starter
    }

    public static let empty = PronunciationList(starterEnabled: true, entries: [], starter: [])

    enum CodingKeys: String, CodingKey {
        case entries, starter
        case starterEnabled = "starter_enabled"
    }
}

public enum PronunciationError: Error, Sendable, Equatable {
    /// The daemon refused it; `detail` is its sentence for the user.
    case rejected(reason: String, detail: String)
    case transport(String)
    case decode(String)

    public var message: String {
        switch self {
        case .rejected(_, let detail): return detail
        case .transport:
            return "Myna's background service didn't answer. Check it's running on the Engine page."
        case .decode: return "Myna's background service answered in a way this app doesn't understand."
        }
    }
}

public actor PronunciationClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL = DaemonClient.defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = DaemonClient.defaultRequestTimeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func list() async throws -> PronunciationList {
        try await send("/v2/pronunciations", method: "GET")
    }

    /// Adds an entry, or replaces the say of the one for the same word.
    public func add(word: String, say: String) async throws -> PronunciationList {
        try await send("/v2/pronunciations", method: "POST", body: Edit(word: word, say: say, enabled: true))
    }

    public func edit(id: String, word: String? = nil, say: String? = nil, enabled: Bool? = nil)
        async throws -> PronunciationList {
        try await send(path(id), method: "PATCH", body: Edit(word: word, say: say, enabled: enabled))
    }

    public func delete(id: String) async throws -> PronunciationList {
        try await send(path(id), method: "DELETE")
    }

    /// The whole starter list on or off.
    public func setStarter(enabled: Bool) async throws -> PronunciationList {
        try await send("/v2/pronunciations/starter", method: "PATCH", body: Switch(enabled: enabled))
    }

    public func setStarterEntry(id: String, enabled: Bool) async throws -> PronunciationList {
        try await send("/v2/pronunciations/starter/" + escaped(id), method: "PATCH", body: Switch(enabled: enabled))
    }

    // MARK: - wire

    private struct Edit: Encodable {
        let word: String?
        let say: String?
        let enabled: Bool?
    }

    private struct Switch: Encodable {
        let enabled: Bool
    }

    private struct Refusal: Decodable {
        let reason: String?
        let detail: String?
    }

    private func path(_ id: String) -> String { "/v2/pronunciations/" + escaped(id) }

    private func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? id
    }

    private func send(_ path: String, method: String) async throws -> PronunciationList {
        try await send(path, method: method, body: Optional<Switch>.none)
    }

    private func send<Body: Encodable>(_ path: String, method: String, body: Body?) async throws -> PronunciationList {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw PronunciationError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PronunciationError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw PronunciationError.transport("not HTTP") }
        guard http.statusCode == 200 else {
            let refusal = try? decoder.decode(Refusal.self, from: data)
            throw PronunciationError.rejected(
                reason: refusal?.reason ?? "http_\(http.statusCode)",
                detail: refusal?.detail ?? "Myna's background service refused that (HTTP \(http.statusCode)).")
        }
        do {
            return try decoder.decode(PronunciationList.self, from: data)
        } catch {
            throw PronunciationError.decode(String(describing: error))
        }
    }
}
