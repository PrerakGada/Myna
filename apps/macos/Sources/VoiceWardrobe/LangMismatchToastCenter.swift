// LangMismatchToastCenter.swift — single observable singleton that
// holds the most-recent "detected: foreign language" hint from the
// daemon. SwiftUI views observe it and decide whether to render a
// transient chip/toast.
//
// We DON'T auto-switch voices — the daemon explicitly leaves that to
// the client. For v0.2 we surface the hint via os_log and an
// @Published property that the menu bar view consumes; a richer UI
// (chip with "Switch voice?" action) can be wired in a later cycle.
import Foundation
import os

@MainActor
public final class LangMismatchToastCenter: ObservableObject {
    /// Singleton because the dispatcher creates a fresh synthesize per
    /// invocation; we'd otherwise have to ferry a store reference
    /// across the App / Dispatcher boundary just for one toast.
    public static let shared = LangMismatchToastCenter()

    /// The latest mismatch, or nil if we've never seen one or it was
    /// dismissed. Views observe this to render their chip.
    @Published public private(set) var latest: SynthesizeMetadata?

    /// Token that increments each time `surface` is called; views can
    /// use this to schedule an auto-dismiss timer that ignores
    /// already-dismissed toasts.
    @Published public private(set) var token: Int = 0

    private let log = Log(.network)

    private init() {}

    /// Record a metadata payload from a synthesize response. We only
    /// surface a toast when `langMismatch == true` AND a detected
    /// language is present — pure "detected English" hints are noise.
    public func surface(_ metadata: SynthesizeMetadata) {
        guard metadata.langMismatch, let lang = metadata.detectedLang else {
            log.debug(
                "lang detected=\(metadata.detectedLang ?? "nil") mismatch=\(metadata.langMismatch) — no toast"
            )
            return
        }
        log.info("lang mismatch detected: \(lang)")
        self.latest = metadata
        self.token += 1
    }

    /// Dismiss the current toast.
    public func dismiss() {
        self.latest = nil
    }
}
