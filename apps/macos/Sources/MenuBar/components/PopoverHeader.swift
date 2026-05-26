// PopoverHeader.swift — top row of the popover. Bird glyph + product
// name + version + colored status dot indicating the current IconState.
import SwiftUI

public struct PopoverHeader: View {
    public let iconState: IconState
    public let versionString: String

    public init(iconState: IconState, versionString: String? = nil) {
        self.iconState = iconState
        self.versionString = versionString ?? PopoverHeader.defaultVersion()
    }

    public var body: some View {
        HStack(spacing: 8) {
            BirdIcon.image
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PopoverDesign.bodyColor)
            Text("Myna")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PopoverDesign.bodyColor)
            Text("v\(versionString)")
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.secondaryColor)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(statusLabel)
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
            }
        }
    }

    private var dotColor: Color {
        switch iconState {
        case .idle: return PopoverDesign.dotIdle
        case .speaking: return PopoverDesign.dotSpeaking
        case .thinking: return PopoverDesign.dotThinking
        case .paused: return PopoverDesign.dotPaused
        case .error: return PopoverDesign.dotError
        }
    }

    private var statusLabel: String {
        switch iconState {
        case .idle: return "idle"
        case .speaking: return "speaking"
        case .thinking: return "thinking"
        case .paused: return "paused"
        case .error: return "offline"
        }
    }

    /// Bundle CFBundleShortVersionString fallback. Stays public-static so
    /// tests can pin a known value without pulling in Bundle.main.
    public static func defaultVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }
}
