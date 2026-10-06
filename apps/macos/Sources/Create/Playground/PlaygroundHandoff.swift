// PlaygroundHandoff.swift — text the Playground passes to Studio.
//
// A single take tops out at 40,000 characters (RENDER_API.md §1). Past
// that the Playground offers "Send to Studio", which parks the editor's
// text here and switches panes. Studio may take it with
// `takeStudioText()` when it appears; if it doesn't, nothing is lost —
// the text is still in the Playground's editor.
import Foundation

@MainActor
enum PlaygroundHandoff {
    /// Written only by the Playground. Read-and-clear with `takeStudioText()`.
    static var pendingStudioText: String?

    /// Returns the waiting text once, then forgets it.
    static func takeStudioText() -> String? {
        defer { pendingStudioText = nil }
        return pendingStudioText
    }
}
