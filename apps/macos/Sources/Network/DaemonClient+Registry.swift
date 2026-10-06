// DaemonClient+Registry.swift — Claude Code registry calls (/v2/registry/*).
//
// Split out of DaemonClient.swift to keep that file under the lint length
// limits. Uses the client's module-internal request helpers.
import Foundation

extension DaemonClient {
    // MARK: - v0.2 Track B endpoints (registry v2)

    /// `GET /v2/registry/list` — fetch pending CC announcements for the
    /// toast pipeline (S08). Returns an empty pending array if the
    /// endpoint is not yet implemented (404) so callers can treat
    /// "no pending" and "endpoint not deployed" identically.
    public func registryListV2() async throws -> RegistryListResponse {
        let req = try makeRequest(path: "/v2/registry/list", method: "GET")
        do {
            return try await decode(req)
        } catch DaemonError.notFound {
            return RegistryListResponse(pending: [])
        } catch DaemonError.http(let code, _) where code == 404 {
            return RegistryListResponse(pending: [])
        }
    }

    /// `POST /v2/registry/announce` — used by stop-hook integrations.
    /// Lane A exposes this primarily so tests + the future demo CLI
    /// can drive the pipeline without going through the Python daemon.
    public func registryAnnounceV2(_ request: RegistryAnnounceRequest) async throws -> RegistryAnnounceResponse {
        let req = try makeRequest(path: "/v2/registry/announce", method: "POST", body: request)
        return try await decode(req)
    }

    /// `POST /v2/registry/play/{id}` — kick off playback for a queued
    /// CC item (toast click → daemon synthesises + plays through the
    /// existing pipeline). `text`, when given, is spoken instead of the
    /// stored reply (the bold-claims setting).
    public func registryPlayV2(id: String, text: String? = nil) async throws -> PlayResponse {
        let path = "/v2/registry/play/\(id)"
        let req = try text.map {
            try makeRequest(path: path, method: "POST", body: RegistryPlayRequest(text: $0))
        } ?? makeRequest(path: path, method: "POST")
        return try await decode(req)
    }

    /// `POST /v2/registry/dismiss/{id}` — take a CC item off the pending
    /// list without the daemon speaking it. Used when the app plays the
    /// reply itself, so the in-process player (and the pill) owns the audio.
    public func registryDismissV2(id: String) async throws -> PlayResponse {
        let req = try makeRequest(path: "/v2/registry/dismiss/\(id)", method: "POST")
        return try await decode(req)
    }

    /// `POST /v2/registry/partly_heard/{id}` — hand back the unheard rest of
    /// a reply Myna auto-read while the user was away. The daemon replaces
    /// the entry with a fresh pending one marked "Partly heard".
    public func registryPartlyHeardV2(id: String, text: String) async throws -> RegistryPartlyHeardResponse {
        let req = try makeRequest(
            path: "/v2/registry/partly_heard/\(id)", method: "POST",
            body: RegistryPartlyHeardRequest(text: text))
        return try await decode(req)
    }
}
