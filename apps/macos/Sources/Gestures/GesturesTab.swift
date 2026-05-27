// GesturesTab.swift — Settings tab for the v0.2 trackpad gestures
// feature. The toggle lives here so users have one obvious place to
// flip it on, alongside an honest "known limitations" note that
// explains the OS gesture conflicts and the 4-finger-tap gap.
//
// This is a pure settings view — no NSEvent hooks. The AppDelegate
// owns the GestureMonitor and observes `settings.trackpadGesturesEnabled`
// to start/stop it.
import SwiftUI

public struct GesturesTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("Trackpad gestures (opt-in)") {
                Toggle("Enable trackpad gestures", isOn: $viewModel.trackpadGesturesEnabled)
            }

            Section("What works") {
                LabeledContent("Swipe left / right (4 fingers)") {
                    Text("Seek backwards / forwards 30s").foregroundStyle(.secondary)
                }
                LabeledContent("Force-touch click") {
                    Text("Pause / resume current playback").foregroundStyle(.secondary)
                }
            }

            Section("Known limitations") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 4-finger tap is not currently recognized.")
                    Text(
                        "  Public macOS APIs don't expose finger counts on "
                        + "global tap events. Use the keyboard hotkey "
                        + "(⌥⇧⌘ S) or a Hammerspoon recipe instead."
                    )
                    .foregroundStyle(.secondary)

                    Text("• 4-finger swipes can conflict with Mission Control.")
                    Text(
                        "  In System Settings → Trackpad → More Gestures, "
                        + "either disable \"Swipe between full-screen apps\" "
                        + "with 4 fingers, or set it to 3 fingers so Myna "
                        + "owns 4."
                    )
                    .foregroundStyle(.secondary)

                    Text("• Force-touch click finger count is approximate.")
                    Text(
                        "  Global pressure events don't include touch lists, "
                        + "so any deep-press counts. Light/medium clicks are "
                        + "ignored."
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(width: 460, height: 380)
    }
}
