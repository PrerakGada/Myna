// VoiceWardrobeStore.swift — observable store for the {bundle_id ->
// voice_id} mapping the daemon owns. Wraps DaemonClient calls into a
// SwiftUI-friendly ObservableObject.
//
// The store does NOT persist anything locally — the daemon is the
// single source of truth. Refresh on appear, push every mutation
// upstream, refresh after.
import Combine
import Foundation
import os

@MainActor
public final class VoiceWardrobeStore: ObservableObject {
    /// `{ bundle_id: voice_id }` mirror of what the daemon last told us.
    @Published public private(set) var mappings: [String: String] = [:]
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastError: String?

    private let client: DaemonClient
    private let log = Log(.network)

    public init(client: DaemonClient) {
        self.client = client
    }

    /// Pull the wardrobe from the daemon. Called from `.task { … }`
    /// in the view; idempotent (no caching beyond `mappings`).
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resp = try await client.voiceWardrobe()
            self.mappings = resp.mappings
            self.lastError = nil
        } catch {
            self.lastError = "\(error)"
            self.log.error("voiceWardrobe refresh failed: \(error)")
        }
    }

    /// Upsert a mapping. Pass voiceId=nil to remove.
    public func set(bundleId: String, voiceId: String?) async {
        let trimmed = bundleId.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let resp = try await client.setVoiceWardrobe(
                bundleId: trimmed,
                voiceId: voiceId
            )
            self.mappings = resp.mappings
            self.lastError = nil
        } catch {
            self.lastError = "\(error)"
            self.log.error("voiceWardrobe set failed: \(error)")
        }
    }

    /// Convenience: remove by bundle id. Equivalent to set(_, nil).
    public func remove(bundleId: String) async {
        await set(bundleId: bundleId, voiceId: nil)
    }
}
