// HotkeysTab.swift — records the five global Myna actions.
//
// We render each action with our own `ShortcutRecorderView` (a thin
// wrapper over the KeyboardShortcuts library's AppKit recorder) instead of
// the library's stock SwiftUI `Recorder`, so we can block paste / typed
// text in the recorder field.
//
// "Reset to Defaults" restores every binding to its built-in chord. This
// is the escape hatch for a "shortcut lockup": if a user records a chord
// that collides with something else (or one that simply never fires), one
// click puts every action back to a known-good default.
import KeyboardShortcuts
import SwiftUI

public struct HotkeysTab: View {
    public init() {}

    private struct ShortcutRow: Identifiable {
        let label: String
        let name: KeyboardShortcuts.Name
        // Stable identity = the shortcut name (Hashable). A per-init UUID
        // would give the rows new identities on every SettingsView
        // re-render, needlessly tearing down/recreating the recorder
        // NSViews (and re-registering the paste observer).
        var id: KeyboardShortcuts.Name { name }
    }

    private let rows: [ShortcutRow] = [
        .init(label: "Speak selection (full):", name: .speakSelectionFull),
        .init(label: "Speak selection (summary):", name: .speakSelectionSummary),
        .init(label: "Read Chrome article:", name: .readChromeArticle),
        .init(label: "Pause / resume:", name: .pauseResume),
        .init(label: "Stop:", name: .stop),
    ]

    public var body: some View {
        Form {
            Section {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                        Spacer(minLength: 12)
                        ShortcutRecorderView(name: row.name)
                            .fixedSize()
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Click a recorder and press the chord you want. Press Delete to clear an action, Escape to cancel. Pasting text is not allowed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            KeyboardShortcuts.reset(KeyboardShortcuts.Name.allMynaShortcuts)
                        }
                        .help("Restore every Myna shortcut to its original default (⌥⇧⌘S, ⌥⇧⌘A, …). Use this if a shortcut stops responding after a bad chord.")
                    }
                }
            }
        }
        .padding()
        .frame(width: 420, height: 300)
    }
}
