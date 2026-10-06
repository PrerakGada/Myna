// SelectionCaptureCard.swift — the "Reading a selection" card at the top
// of the Reading pane: how the read shortcut gets the text, the escape
// hatch for an app whose Accessibility answer is wrong, and the Services
// menu route that needs no permission.
//
// Its own file so the Reading pane (ControlPanes.swift) only gains one line.
import SwiftUI

struct SelectionCaptureCard: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Reading a selection")
                    .padding(.bottom, 6)
                DashRow("Selection capture", help: Self.captureHelp) {
                    Picker("", selection: $settings.selectionCaptureMode) {
                        ForEach(SelectionCaptureMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
                DashDivider()
                DashRow("From the Services menu", help: Self.servicesHelp) {
                    Text("Read with Myna")
                        .foregroundStyle(DashboardDesign.secondary)
                }
            }
        }
    }

    // Kept as constants: the CI compiler refuses to type-check chained
    // string concatenation inside a ViewBuilder (see GesturesPane).
    static let captureHelp =
        "Automatic asks the app for the selected text through Accessibility and leaves "
        + "your clipboard alone. If the app gives nothing back, Myna copies with ⌘C and "
        + "then puts your clipboard back. Copy only always uses ⌘C: pick it if an app "
        + "reads the wrong text."
    static let servicesHelp =
        "Right-click selected text in any app and choose Services ▸ Read with Myna, or "
        + "Summarize with Myna. Works without Accessibility permission. If the items are "
        + "missing, launch Myna once, then check System Settings ▸ Keyboard ▸ Keyboard "
        + "Shortcuts ▸ Services."
}
