// HotkeysTab.swift — uses KeyboardShortcuts.Recorder for each of the
// five Myna actions. The library handles capture and conflict logic.
import KeyboardShortcuts
import SwiftUI

public struct HotkeysTab: View {
    public init() {}

    public var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Speak selection (full):", name: .speakSelectionFull)
                KeyboardShortcuts.Recorder("Speak selection (summary):", name: .speakSelectionSummary)
                KeyboardShortcuts.Recorder("Read Chrome article:", name: .readChromeArticle)
                KeyboardShortcuts.Recorder("Pause / resume:", name: .pauseResume)
                KeyboardShortcuts.Recorder("Stop:", name: .stop)
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("Click a recorder and press the chord you want. Press Escape to clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 420, height: 260)
    }
}
