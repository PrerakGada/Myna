// PopoverHeader.swift — top row of the popover. Bird glyph + product
// name + version, and a tinted status pill on the right.
//
// The status used to be a bare dot and a lowercase word, immediately
// above a hero card whose entire job was to restate the same thing
// ("READY / No audio playing"). With the hero gone in the idle case,
// this pill is the only status readout — so it carries its own tint and
// says the state in words a person would use.
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
            BirdIcon.artwork
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
            Text("Myna")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PopoverDesign.bodyColor)
            Text("v\(versionString)")
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.secondaryColor.opacity(0.7))
            Spacer(minLength: 0)
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dotColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(dotColor.opacity(0.14)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusLabel)")
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

    /// Words, not enum names. "thinking" told the user nothing about what
    /// Myna was doing with their text.
    private var statusLabel: String {
        switch iconState {
        case .idle: return "Ready"
        case .speaking: return "Reading"
        case .thinking: return "Preparing"
        case .paused: return "Paused"
        case .error: return "Offline"
        }
    }

    /// Bundle CFBundleShortVersionString fallback. Stays public-static so
    /// tests can pin a known value without pulling in Bundle.main.
    public static func defaultVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }
}
