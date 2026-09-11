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
                    "Play a tone when a trackpad gesture is detected",
                    isOn: $viewModel.gestureEarconEnabled
                )
                Text(
                    "55ms rising tone (660→880 Hz) at -14dB, the moment the gesture "
                        + "registers — so you know it landed without waiting for speech."
                )
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
                    "When a session finishes, its reply appears in the floating pill with Play and Dismiss. "
                        + "With the pill turned off (Advanced), a card slides in at the top-right instead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 460, height: 320)
    }
}
