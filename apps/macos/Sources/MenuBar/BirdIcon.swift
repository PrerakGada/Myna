// BirdIcon.swift — the menu bar bird. v0.1 uses the SF Symbol "bird"
// so we ship something recognizable immediately; a custom asset can
// land later without API churn (callers just call BirdIcon.image).
import SwiftUI

public enum BirdIcon {
    /// Returns a SwiftUI Image for the menu bar. State-suffix glyphs
    /// (▸ playing, ‖ paused, ! down) are layered via MenuBarView's
    /// Label, not into the image itself, so dark/light mode stays
    /// correct without per-icon adjustments.
    public static var image: Image {
        Image(systemName: "bird")
    }

    public static var systemName: String { "bird" }
}
