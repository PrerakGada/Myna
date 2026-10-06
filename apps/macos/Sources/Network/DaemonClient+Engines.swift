// DaemonClient+Engines.swift — voice engine catalog calls (/v2/engines).
//
// Split out of DaemonClient.swift to keep that file under the lint length
// limits. Uses the client's module-internal request helpers.
import Foundation

// MARK: - Voice engines (/v2/engines)

extension DaemonClient {
    public func engines() async throws -> EnginesResponse {
        let req = try makeRequest(path: "/v2/engines", method: "GET")
        return try await decode(req)
    }

    /// Starts a background download; poll `engines()` for progress.
    public func installEngine(id: String) async throws -> EngineEntry {
        let req = try makeRequest(path: "/v2/engines/\(id)/install", method: "POST")
        return try await engineAction(req)
    }

    /// Loads the engine and makes it the voice. Slow on a cold model (the
    /// daemon speaks a warm-up line before answering), hence the long timeout.
    public func activateEngine(id: String) async throws -> EngineActivateResponse {
        var req = try makeRequest(path: "/v2/engines/\(id)/activate", method: "POST")
        req.timeoutInterval = 300
        return try await engineAction(req)
    }

    public func removeEngine(id: String) async throws -> EngineEntry {
        let req = try makeRequest(path: "/v2/engines/\(id)", method: "DELETE")
        return try await engineAction(req)
    }

    private func engineAction<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw DaemonError.transport(urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DaemonError.transport("non-http response")
        }
        guard http.statusCode == 200 else {
            throw EngineActionError.from(status: http.statusCode, body: data)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DaemonError.decode(String(describing: error))
        }
    }
}
