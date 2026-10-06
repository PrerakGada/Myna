// TextCleanupCard.swift — the Reading pane's "Text cleanup" section.
//
// One master switch and one per source. They don't configure the daemon:
// each read sends the resulting prep (SettingsViewModel.textPrep(for:)), so
// the rules are the daemon's (daemon/myna/speakable.py) and the choice of
// whether to apply them is the app's.
import SwiftUI

struct TextCleanupCard: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Text cleanup")
                    .padding(.bottom, 6)
                DashRow(
                    "Clean up text before reading",
                    help: "Reads the words, not the formatting: markdown symbols, code blocks, "
                        + "citation marks like [12] and table lines are left out, and a web address "
                        + "is read as its site name. Off reads everything exactly as written."
                ) {
                    Toggle("", isOn: $settings.textCleanup)
                        .labelsHidden().toggleStyle(.switch)
                }
                DashDivider()
                DashRow(
                    "Claude Code replies",
                    help: "Also skips code and diffs without saying so, and reads a file path as its "
                        + "file name: “app.py line 42”."
                ) {
                    Toggle("", isOn: $settings.textCleanupClaudeCode)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!settings.textCleanup)
                }
                DashDivider()
                DashRow(
                    "Articles",
                    help: "Also leaves out figure captions, “Advertisement” lines and the "
                        + "reference list at the end."
                ) {
                    Toggle("", isOn: $settings.textCleanupArticles)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!settings.textCleanup)
                }
                DashDivider()
                DashRow("Selected and copied text", help: "Only the cleanup described above.") {
                    Toggle("", isOn: $settings.textCleanupSelection)
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!settings.textCleanup)
                }
            }
        }
    }
}
