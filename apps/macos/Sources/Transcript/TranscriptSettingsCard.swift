// TranscriptSettingsCard.swift — the Reading pane's transcript section.
//
// Its own file, inserted into ReadingPane with one line, like the queue's
// card. Binds straight to the defaults TranscriptStore and the open buttons
// read, so a change applies to the next read (and hides the buttons at once).
import SwiftUI

struct TranscriptSettingsCard: View {
    @AppStorage(TranscriptVisibility.defaultsKey)
    private var visibility: TranscriptVisibility = TranscriptVisibility.defaultValue
    @AppStorage(TranscriptAutoOpen.defaultsKey)
    private var autoWords: Int = TranscriptAutoOpen.defaultWords

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Transcript")
                    .padding(.bottom, 6)
                DashRow(
                    "Show the transcript while reading",
                    help: "A window with the text being read, the current sentence lit. Open it "
                        + "from the pill or the Dashboard's now-playing strip. Off hides those buttons."
                ) {
                    Picker("", selection: $visibility) {
                        ForEach(TranscriptVisibility.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .onChange(of: visibility) { value in
                        if value == .off { TranscriptPanelController.shared.close() }
                    }
                }
                DashDivider()
                DashRow(
                    "Open it by itself for reads longer than",
                    help: "Counted as the text arrives, so a long article opens the transcript "
                        + "when its reading starts."
                ) {
                    Picker("", selection: $autoWords) {
                        ForEach(TranscriptAutoOpen.choices, id: \.self) { words in
                            Text("\(words.formatted()) words").tag(words)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(visibility != .automatic)
                }
                DashDivider()
                Text(
                    "Click a sentence to play from it. Previous and Next sentence can have "
                        + "shortcuts in the Shortcuts pane. The light is placed by estimate within each "
                        + "part of a read, so it can run slightly ahead or behind the voice; it lines "
                        + "up again at every part."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
            }
        }
    }
}
