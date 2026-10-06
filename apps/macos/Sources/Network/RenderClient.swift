// RenderClient.swift — async client for the render API: finished audio
// files out of the daemon, as opposed to DaemonClient.synthesize, which
// streams a *read* into Myna's player and drives the menu-bar state.
//
// A render never touches the state machine, the karaoke ribbon, the pill
// or History. Contract: docs/native-app/RENDER_API.md.
//
// Same shape as DaemonClient (an actor over an injectable URLSession) so
// tests stub it the same way, with a URLProtocol subclass.
import Foundation

public actor RenderClient {
    /// The app-wide client. AppDelegate replaces it at bootstrap with one
    /// pointed at the daemon address from Settings, the same address
    /// DaemonClient uses, so a custom port reaches every Create pane.
    @MainActor public static var shared = RenderClient()

    /// Short synchronous clips are allowed to take a while on slow engines;
    /// long work belongs in a render job, not here.
    public static let speechTimeout: TimeInterval = 300

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
            cfg.timeoutIntervalForResource = Self.speechTimeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// `http://127.0.0.1:8766/v1` — what an OpenAI client's `base_url` is.
    public nonisolated var openAIBaseURL: URL {
        baseURL.appendingPathComponent("v1")
    }

    // MARK: - POST /v1/audio/speech

    public func speech(_ request: SpeechRequest) async throws -> SpeechResult {
        let trimmed = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenderAPIError.emptyInput }
        var req = try makeRequest(path: "/v1/audio/speech", method: "POST", body: request)
        req.timeoutInterval = Self.speechTimeout
        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw Self.mapError(status: http.statusCode, body: data) }
        func header(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        return SpeechResult(
            audio: data,
            contentType: header("Content-Type") ?? "application/octet-stream",
            engine: header("X-Myna-Engine"),
            voice: header("X-Myna-Voice"),
            durationS: header("X-Myna-Duration-S").flatMap(Double.init),
            sampleRate: header("X-Myna-Sample-Rate").flatMap(Int.init),
            chunks: header("X-Myna-Chunks").flatMap(Int.init),
            renderMs: header("X-Myna-Render-Ms").flatMap(Int.init)
        )
    }

    // MARK: - formats / transcode

    public func formats() async throws -> [AudioFormatInfo] {
        let resp: AudioFormatsResponse = try await decode(try makeRequest(path: "/v2/formats", method: "GET"))
        return resp.formats
    }

    /// Re-encode WAV already in hand (a Playground take) without
    /// re-synthesizing it.
    public func transcode(wav: Data, to format: String) async throws -> Data {
        var req = try makeRequest(path: "/v2/transcode?format=\(format)", method: "POST")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = wav
        req.timeoutInterval = Self.speechTimeout
        let (data, http) = try await send(req)
        guard http.statusCode == 200 else { throw Self.mapError(status: http.statusCode, body: data) }
        return data
    }

    // MARK: - /v2/renders

    public func createRender(_ request: RenderRequest) async throws -> RenderJob {
        try await decode(try makeRequest(path: "/v2/renders", method: "POST", body: request), accept: [200, 201])
    }

    public func renders() async throws -> [RenderJob] {
        let resp: RenderListResponse = try await decode(try makeRequest(path: "/v2/renders", method: "GET"))
        return resp.renders
    }

    public func render(id: String) async throws -> RenderJob {
        try await decode(try makeRequest(path: "/v2/renders/\(id)", method: "GET"))
    }

    public func cancelRender(id: String) async throws -> RenderJob {
        try await decode(try makeRequest(path: "/v2/renders/\(id)/cancel", method: "POST"))
    }

    public func deleteRender(id: String) async throws {
        let (data, http) = try await send(try makeRequest(path: "/v2/renders/\(id)", method: "DELETE"))
        guard http.statusCode == 200 || http.statusCode == 204 else {
            throw Self.mapError(status: http.statusCode, body: data)
        }
    }

    public nonisolated func renderAudioURL(id: String) -> URL {
        baseURL.appendingPathComponent("v2/renders/\(id)/audio")
    }

    // MARK: - /v2/api/*

    public func apiSettings() async throws -> APISettings {
        try await decode(try makeRequest(path: "/v2/api/settings", method: "GET"))
    }

    public func updateAPISettings(_ update: APISettingsUpdate) async throws -> APISettings {
        try await decode(try makeRequest(path: "/v2/api/settings", method: "POST", body: update))
    }

    public func apiLog(limit: Int = 100) async throws -> [APIRequestLogEntry] {
        let resp: APIRequestLogResponse = try await decode(
            try makeRequest(path: "/v2/api/log?limit=\(limit)", method: "GET"))
        return resp.requests
    }

    // MARK: - helpers

    private func makeRequest<Body: Encodable>(path: String, method: String, body: Body) throws -> URLRequest {
        var req = try makeRequest(path: path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return req
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RenderAPIError.transport("bad path \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = DaemonClient.defaultRequestTimeout
        return req
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw RenderAPIError.transport(urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RenderAPIError.transport("non-http response")
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ request: URLRequest, accept: Set<Int> = [200]) async throws -> T {
        let (data, http) = try await send(request)
        guard accept.contains(http.statusCode) else { throw Self.mapError(status: http.statusCode, body: data) }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RenderAPIError.decode(String(describing: error))
        }
    }

    /// Both error shapes: OpenAI's `{"error": {code, message}}` from /v1 and
    /// the daemon's `{"ok": false, reason, detail}` from /v2. FastAPI's
    /// HTTPException wraps the latter in `{"detail": {...}}`.
    static func mapError(status: Int, body: Data) -> RenderAPIError {
        var code: String?
        var message = ""
        if let openAI = try? JSONDecoder().decode(OpenAIErrorShape.self, from: body) {
            code = openAI.error.code
            message = openAI.error.message ?? ""
        } else if let wrapped = try? JSONDecoder().decode(WrappedDaemonErrorShape.self, from: body) {
            code = wrapped.detail.reason
            message = wrapped.detail.detail ?? ""
        } else if let flat = try? JSONDecoder().decode(DaemonErrorShape.self, from: body) {
            code = flat.reason
            message = flat.detail ?? ""
        } else {
            message = String(data: body, encoding: .utf8) ?? ""
        }

        switch code {
        case "empty_input", "empty": return .emptyInput
        case "input_too_long": return .inputTooLong
        case "engine_not_active": return .engineNotActive(message)
        case "format_unavailable": return .formatUnavailable(message)
        case "engine_down": return .engineDown
        case "engine_error": return .engineError(message)
        case "not_ready": return .notReady
        default:
            if status == 404 { return .notFound }
            return .http(status, code: code, message: message)
        }
    }
}

// Error bodies RenderClient.mapError understands.
private struct OpenAIErrorShape: Decodable {
    struct Inner: Decodable {
        let message: String?
        let code: String?
    }
    let error: Inner
}

private struct DaemonErrorShape: Decodable {
    let reason: String?
    let detail: String?
}

private struct WrappedDaemonErrorShape: Decodable {
    let detail: DaemonErrorShape
}
