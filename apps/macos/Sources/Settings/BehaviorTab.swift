// BehaviorTab.swift — Settings tab for v0.2 feature toggles: thinking
// earcon (S07), toast appearance chime + CC toasts (S08).
//
// Per the v0.2 plan, the Settings UI gains this tab without removing
// anything else. Bindings flow into SettingsViewModel's persisted
// @AppStorage / SettingsStore-backed @Published properties.
import SwiftUI

public struct BehaviorTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("Sounds") {
                Toggle(
                    "Play a brief tick when Myna starts thinking",
                    isOn: $viewModel.thinkingEarconEnabled
                )
                Text("80ms low tone (~220 Hz) at -18dB. Never overlaps speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Play a chime when a Claude Code toast appears",
                    isOn: $viewModel.toastChimeEnabled
                )
            }
            Section("Claude Code") {
                Toggle(
                    "Show toasts when Claude finishes",
                    isOn: $viewModel.ccToastsEnabled
                )
                Text(
                    "Toasts appear at the top-right of the active display. "
                        + "macOS Focus mode is respected — when Do Not Disturb is on, "
                        + "toasts route silently to the menu bar instead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 460, height: 320)
    }
}
