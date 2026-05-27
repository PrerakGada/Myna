// GesturesTab.swift — Settings tab for the v0.2.x trackpad gesture
// redesign. Pure SwiftUI form — no NSEvent hooks here. AppDelegate
// owns the GestureMonitor and observes
// `settings.trackpadGesturesEnabled` to start/stop it.
//
// IMPLEMENTATION NOTE
// The CI Swift compiler (universal x86_64 + arm64) refuses to type-
// check more than one or two chained `"a" + "b"` Text concatenations
// inside a single `@ViewBuilder` returning multiple views. So every
// long string is a single Swift triple-quoted literal (no `+`), and
// every "row of two Texts" is a concrete `VStack` rather than two
// loose Texts in a builder. Cosmetic only — no behaviour change.
import SwiftUI

public struct GesturesTab: View {
    @ObservedObject var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            enableSection
            gesturesSection
            howItWorksSection
            limitationsSection
        }
        .padding()
        .frame(width: 480, height: 480)
    }

    // MARK: - sections

    @ViewBuilder
    private var enableSection: some View {
        Section("Trackpad gestures (opt-in)") {
            Toggle("Enable trackpad gestures", isOn: $viewModel.trackpadGesturesEnabled)
            Text("Off by default. When on, Myna listens to the trackpad for four-finger gestures.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var gesturesSection: some View {
        Section("Gestures") {
            LabeledContent("4-finger tap") {
                Text("Speak selection").foregroundStyle(.secondary)
            }
            LabeledContent("4-finger double-tap") {
                Text("Stop").foregroundStyle(.secondary)
            }
            LabeledContent("4-finger click") {
                Text("Play / pause  (debug)").foregroundStyle(.secondary)
            }
            LabeledContent("4-finger double-click") {
                Text("Stop  (debug)").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var howItWorksSection: some View {
        Section("How it works") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hold four fingers on the trackpad to trigger.")
                Text(howItWorksBody)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var limitationsSection: some View {
        Section("Known limitations") {
            VStack(alignment: .leading, spacing: 10) {
                limitRow(headline: "Conflicts with BetterTouchTool & other multitouch utilities.",
                         body: limitConflictBody)
                limitRow(headline: "Requires a built-in or Magic Trackpad.",
                         body: limitTrackpadBody)
                limitRow(headline: "Uses a private macOS framework.",
                         body: limitPrivateAPIBody)
                limitRow(headline: "Click gestures need a click while 4 fingers are touching.",
                         body: limitClickBody)
            }
            .font(.caption)
        }
    }

    // MARK: - limitation row helper

    private func limitRow(headline: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("• " + headline)
            Text(body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - body strings (kept as plain Swift constants so the
    // compiler doesn't have to type-check string concatenation inside
    // a SwiftUI body builder)
    //
    // These are user-facing prose paragraphs rendered verbatim in the
    // Settings → Gestures tab. We keep each paragraph on a single source
    // line so editors can wrap them visually without us hand-breaking
    // sentences — the lint rule isn't useful here.
    // swiftlint:disable line_length

    private let howItWorksBody = """
Tap = brief contact with all four fingers, then lift. Click = press the trackpad firmly while four fingers are down. Double versions need a second tap or click within the system double-click interval.
"""

    private let limitConflictBody = """
  BTT, Magnet, Cinch and similar tools also subscribe to MultitouchSupport's contact-frame callback. Only one app reliably receives the events at a time — whichever started first usually wins. If your gestures aren't firing, quit those apps (or disable their trackpad gestures) and toggle Myna's gestures off and on once to re-subscribe.
"""

    private let limitTrackpadBody = """
  External mice and most Bluetooth keyboards' trackpads are not detected. The toggle stays on but no gestures fire.
"""

    private let limitPrivateAPIBody = """
  Public NSEvent APIs don't expose trackpad finger counts for global gestures, so Myna reads them from Apple's MultitouchSupport framework. This framework has powered BetterTouchTool, Magnet, Hammerspoon and similar tools for 15+ years; if Apple ever removes it, gestures will stop working and Myna will fall back to hotkeys only.
"""

    private let limitClickBody = """
  Press the trackpad firmly enough to actuate the click (the haptic feedback / audible click). Force Touch is not required — a normal click works on any trackpad.
"""
    // swiftlint:enable line_length
}
