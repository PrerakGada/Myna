// ReadQueueSettingsCard.swift — the Reading pane's queue section.
//
// Its own file, inserted into ReadingPane with one line, because other
// features add their own sections to that pane and a shared file is where
// merges go wrong. Binds straight to the defaults key AppDispatcher reads on
// every key press, so a change applies to the very next read.
import SwiftUI

struct ReadQueueSettingsCard: View {
    @AppStorage(ReadKeyWhileReading.defaultsKey)
    private var readKey: ReadKeyWhileReading = ReadKeyWhileReading.defaultValue

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("While Myna is reading")
                    .padding(.bottom, 6)
                DashRow(
                    "When Myna is already reading, the read key",
                    help: "Adds to the queue: the new read waits and plays when the current one "
                        + "finishes. Interrupts: the new read replaces the current one. Also covers "
                        + "the summary and article shortcuts, trackpad gestures, and the menu's "
                        + "clipboard and Chrome reads."
                ) {
                    Picker("", selection: $readKey) {
                        ForEach(ReadKeyWhileReading.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                DashDivider()
                Text(
                    "Play on a History row, a Recent row or a Claude Code reply always starts at "
                        + "once. Stop clears the queue; Skip moves to the next read. The queue holds "
                        + "up to \(ReadQueue.defaultCapacity) reads and is emptied when Myna quits."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
            }
        }
    }
}
