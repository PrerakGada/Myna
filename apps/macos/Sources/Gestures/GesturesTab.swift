// GesturesTab.swift — Settings tab for the v0.2.x trackpad gesture
// redesign. Pure SwiftUI form — no NSEvent hooks here. AppDelegate
// owns the GestureMonitor and observes
// `settings.trackpadGesturesEnabled` to start/stop it.
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
                Text(
                    "Off by default. When on, Myna listens to the trackpad "
                    + "for four-finger gestures. Requires a Force Touch "
                    + "trackpad for the click gestures."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Gestures") {
                LabeledContent("4-finger tap") {
                    Text("Speak selection").foregroundStyle(.secondary)
                }
                LabeledContent("4-finger double-tap") {
                    Text("Speak selection (summary)").foregroundStyle(.secondary)
                }
                LabeledContent("4-finger click") {
                    Text("Play / pause").foregroundStyle(.secondary)
                }
                LabeledContent("4-finger double-click") {
                    Text("Stop").foregroundStyle(.secondary)
                }
            }

            Section("How it works") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hold four fingers on the trackpad to trigger.")
                    Text(
                        "Tap = brief contact with all four fingers, then lift. "
                        + "Click = press hard (Force Touch) while four fingers "
                        + "are down. Double versions need a second tap or click "
                        + "within the system double-click interval."
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            Section("Known limitations") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• Conflicts with BetterTouchTool & other multitouch utilities.")
                    Text(
                        "  BTT, Magnet, Cinch and similar tools also subscribe to "
                        + "MultitouchSupport's contact-frame callback. Only one app "
                        + "reliably receives the events at a time — whichever started "
                        + "first usually wins. If your gestures aren't firing, quit "
                        + "those apps (or disable their trackpad gestures) and "
                        + "toggle Myna's gestures off and on once to re-subscribe."
                    )
                    .foregroundStyle(.secondary)

                    Text("• Requires a built-in or Magic Trackpad.")
                    Text(
                        "  External mice and most Bluetooth keyboards' trackpads "
                        + "are not detected. The toggle stays on but no gestures fire."
                    )
                    .foregroundStyle(.secondary)

                    Text("• Uses a private macOS framework.")
                    Text(
                        "  Public NSEvent APIs don't expose trackpad finger counts "
                        + "for global gestures, so Myna reads them from Apple's "
                        + "MultitouchSupport framework. This framework has powered "
                        + "BetterTouchTool, Magnet, Hammerspoon and similar tools "
                        + "for 15+ years; if Apple ever removes it, gestures will "
                        + "stop working and Myna will fall back to hotkeys only."
                    )
                    .foregroundStyle(.secondary)

                    Text("• Click gestures need a Force Touch trackpad.")
                    Text(
                        "  Pre-2015 trackpads don't report a click pressure stage, "
                        + "so the click and double-click gestures will not fire on "
                        + "that hardware. Taps and double-taps still work."
                    )
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(width: 480, height: 480)
    }
}
