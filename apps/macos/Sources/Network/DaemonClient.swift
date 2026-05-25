// DaemonClient.swift — async HTTP client for the Myna daemon.
//
// Actor isolation: we don't actually need mutable state, but using an
// actor gives us a single, clear concurrency boundary and prevents the
// pitfall of accidentally sharing a `URLSession` across configurations.
// Tests can pass an injected `URLSession` configured with a custom
// `URLProtocol` subclass to stub responses without touching the network.
//
// Endpoint URLs follow docs/native-app/API_CONTRACT.md.
import Foundation

public actor DaemonClient {
    public static let defaultBaseURL: URL = {
        // swiftlint:disable:next force_unwrapping
        URL(string: "http://127.0.0.1:8766")!
    }()

    /// Standard timeouts.
    public static let defaultRequestTimeout: TimeInterval = 30
    public static let synthesizeTimeout: TimeInterval = 600  // long: full article

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// In-process voice cache. The daemon also caches, but the client
    /// holds a copy too so we don't refetch on every menu redraw.
    private var cachedVoices: [Voice]?

    public init(baseURL: URL = DaemonClient.defaultBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = DaemonClient.defaultRequestTimeout
            cfg.timeoutIntervalForResource = DaemonClient.synthesizeTimeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - GET /v2/health

    public func health() async throws -> HealthResponse {
        let req = try makeRequest(path: "/v2/health", method: "GET")
        return try await decode(req)
    }

    // MARK: - GET /v2/status

    public func status() async throws -> DaemonStatus {
        let req = try makeRequest(path: "/v2/status", method: "GET")
        return try await decode(req)
    }

    // MARK: - GET /v2/voices

    public func voices(forceRefresh: Bool = false) async throws -> [Voice] {
        if !forceRefresh, let cached = cachedVoices {
            return cached
        }
        let req = try makeRequest(path: "/v2/voices", method: "GET")
        let response: VoicesResponse = try await decode(req)
        cachedVoices = response.voices
        return response.voices
    }

    // MARK: - POST /v2/extract

    public func extract(url: String) async throws -> ExtractResponse {
        try Self.validateHTTPURL(url)
        let req = try makeRequest(path: "/v2/extract", method: "POST", body: ExtractRequest(url: url))
        let resp: ExtractResponse = try await decode(req)
        if !resp.ok {
            throw DaemonError.extractFailed
        }
        return resp
    }

    // MARK: - POST /v2/summarize

    public func summarize(text: String) async throws -> SummarizeResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DaemonError.empty }
        let req = try makeRequest(path: "/v2/summarize", method: "POST", body: SummarizeRequest(text: text))
        return try await decode(req)
    }

    // MARK: - POST /v2/synthesize

    /// Stream of audio chunks for the given synthesize request.
    /// Caller iterates with `for try await chunk in stream { ... }`.
    public nonisolated func synthesize(_ request: SynthesizeRequest) -> AsyncThrowingStream<SynthesizedChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.runSynthesize(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runSynthesize(
        _ request: SynthesizeRequest,
        continuation: AsyncThrowingStream<SynthesizedChunk, Error>.Continuation
    ) async throws {
        try Self.validateSynthesizeRequest(request)
        var req = try makeRequest(path: "/v2/synthesize", method: "POST", body: request)
        req.timeoutInterval = Self.synthesizeTimeout
        req.setValue("multipart/mixed", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await sessionBytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DaemonError.transport("non-http response")
        }
        if http.statusCode != 200 {
            let body = try await collect(bytes: bytes)
            throw mapHTTPError(status: http.statusCode, body: body)
        }

        let boundary = parseBoundary(from: http.value(forHTTPHeaderField: "Content-Type")) ?? "mynachunk"
        let parser = MultipartChunkParser(boundary: boundary)
        try await consumeStream(bytes, into: parser, yielding: continuation)
    }

    /// Validate text/url/scheme constraints up front so we don't make a
    /// pointless round trip.
    private static func validateSynthesizeRequest(_ request: SynthesizeRequest) throws {
        let hasText = !(request.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasURL = !(request.url?.isEmpty ?? true)
        if !hasText && !hasURL { throw DaemonError.empty }
        if hasText && hasURL { throw DaemonError.bothTextAndURL }
        if hasURL, let url = request.url {
            try Self.validateHTTPURL(url)
        }
    }

    /// Drains the response stream into the parser and yields fully-formed
    /// chunks. URL transport errors are mapped to DaemonError.
    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        into parser: MultipartChunkParser,
        yielding continuation: AsyncThrowingStream<SynthesizedChunk, Error>.Continuation
    ) async throws {
        var pending = Data()
        do {
            for try await byte in bytes {
                pending.append(byte)
                if pending.count >= 4_096 {
                    parser.append(pending)
                    pending.removeAll(keepingCapacity: true)
                    yieldAudioParts(try parser.drain(), to: continuation)
                    if parser.isFinished { return }
                }
            }
            if !pending.isEmpty { parser.append(pending) }
            yieldAudioParts(try parser.drain(), to: continuation)
        } catch let urlError as URLError {
            throw DaemonError.transport(urlError.localizedDescription)
        }
    }

    private func yieldAudioParts(
        _ parts: [MultipartPart],
        to continuation: AsyncThrowingStream<SynthesizedChunk, Error>.Continuation
    ) {
        for part in parts {
            if case .audio(let chunk) = part {
                continuation.yield(chunk)
            }
        }
    }

    // MARK: - POST /announce (v1 endpoint, still used by clients)

    public func announce(sessionId: String, label: String, text: String) async throws -> AnnounceResponse {
        let req = try makeRequest(
            path: "/announce",
            method: "POST",
            body: AnnounceRequest(sessionId: sessionId, label: label, text: text)
        )
        return try await decode(req)
    }

    // MARK: - GET /registry

    public func registry() async throws -> RegistryInfo {
        let req = try makeRequest(path: "/registry", method: "GET")
        // The v1 endpoint returns `{ "items": [...] }`, not the v2 RegistryInfo
        // shape with `count`. Decode loosely and synthesize the count.
        struct V1Registry: Decodable { let items: [RegistryItem] }
        let v1: V1Registry = try await decode(req)
        return RegistryInfo(count: v1.items.count, items: v1.items)
    }

    // MARK: - POST /play/{id}?mode=full|summary

    public func playItem(id: String, mode: PlayMode) async throws -> PlayResponse {
        let path = "/play/\(id)?mode=\(mode.rawValue)"
        let req = try makeRequest(path: path, method: "POST")
        let resp: PlayResponse = try await decode(req)
        if !resp.ok, resp.reason == "not_found" {
            throw DaemonError.notFound
        }
        return resp
    }

    // MARK: - Helpers

    private func makeRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body
    ) throws -> URLRequest {
        var req = try makeRequest(path: path, method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return req
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DaemonError.invalidURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = Self.defaultRequestTimeout
        return req
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw DaemonError.transport(urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DaemonError.transport("non-http response")
        }
        if http.statusCode != 200 {
            throw mapHTTPError(status: http.statusCode, body: data)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DaemonError.decode(String(describing: error))
        }
    }

    private func sessionBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw DaemonError.transport(urlError.localizedDescription)
        }
    }

    private func collect(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func parseBoundary(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("boundary=") {
                let value = kv.dropFirst("boundary=".count)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private func mapHTTPError(status: Int, body: Data) -> DaemonError {
        struct ErrPayload: Decodable {
            let ok: Bool?
            let reason: String?
            let detail: String?
        }
        let payload = try? JSONDecoder().decode(ErrPayload.self, from: body)
        switch (status, payload?.reason) {
        case (400, "empty"): return .empty
        case (400, "both_text_and_url"): return .bothTextAndURL
        case (400, "neither_text_nor_url"): return .neitherTextNorURL
        case (400, "extract_failed"): return .extractFailed
        case (404, _): return .notFound
        case (502, "engine_down"): return .engineDown
        case (502, "engine_error"): return .engineError(payload?.detail ?? "")
        case (504, _): return .engineTimeout
        default:
            let text = String(data: body, encoding: .utf8) ?? ""
            return .http(status, text)
        }
    }

    /// Reject anything that's not a plain `http://` or `https://` URL.
    /// This catches `file://`, `myna://`, malformed strings, etc. before
    /// they hit the daemon.
    public static func validateHTTPURL(_ url: String) throws {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            throw DaemonError.invalidURL(url)
        }
        guard scheme == "http" || scheme == "https" else {
            throw DaemonError.invalidURL(url)
        }
    }
}
