// PillBridge.swift — a tiny @MainActor ObservableObject that the
// FloatingPill module exposes to the rest of the app for *optional*
// enrichment (current chunk preview text, custom voice label override).
//
// Rationale: the existing AudioPlayer publishes state/position/duration
// but does not carry the source text of the chunk it's playing. Adding
// `currentText` to AudioPlayer is out of scope for the v0.2.x pill lane
// (which is forbidden from touching `Sources/Audio/**`), so the pill
// renders gracefully without it (voice + "Speaking…" status only).
//
// Later PRs that want to surface the chunk preview can — without
// touching FloatingPill — push into `PillBridge.shared`:
//
//     PillBridge.shared.publish(currentText: text, voice: voiceId)
//
// and the pill will pick it up automatically via @ObservedObject.
//
// Concurrency: @MainActor because every consumer is SwiftUI / NSPanel.
import Combine
import Foundation

@MainActor
public final class PillBridge: ObservableObject {
    public static let shared = PillBridge()

    /// Most-recent preview text the dispatcher (or any other producer)
    /// asked Myna to speak. Nil until someone publishes. Truncate at
    /// the view layer — the bridge stores the full string so a future
    /// expanded view can show more if it wants.
    @Published public private(set) var currentText: String?

    /// Voice label currently in flight. Pill falls back to
    /// `SettingsViewModel.voice` when this is nil.
    @Published public private(set) var currentVoice: String?

    public init() {}

    /// Atomically publish a new speech session. Pass nil to clear.
    public func publish(currentText: String?, voice: String? = nil) {
        self.currentText = currentText
        self.currentVoice = voice
    }

    /// Clear all bridge state (e.g. on stop).
    public func clear() {
        currentText = nil
        currentVoice = nil
    }
}
