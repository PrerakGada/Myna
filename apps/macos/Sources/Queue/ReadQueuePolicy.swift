// ReadQueuePolicy.swift — which reads wait their turn and which cut in.
//
// The rule: a key press while Myna is reading means "that too", so it
// queues; a click on something already on screen means "play this", so it
// interrupts. The user can flip the key side to "Interrupts" in the Reading
// pane (the pre-queue behaviour). Clicks always interrupt.
//
// Every way a read reaches AppDispatcher, and where it lands:
//
//   selectionKey  speak-selection hotkeys (full and summary), the trackpad
//                 gesture, myna://speak-selection          → the preference
//   articleKey    the article hotkey, the popover's Chrome row,
//                 myna://read-chrome                        → the preference
//   clipboard     the popover's Read / Summarize clipboard  → the preference
//   playClick     a Recent row (popover or pill), a History row, a Claude
//                 Code Play (toast, popover card, pill)     → always now
//
// Voice previews never reach the dispatcher: VoicePreviewService plays them
// on its own player and ducks the read underneath, so they neither queue nor
// interrupt.
import Foundation

/// How a read reached the dispatcher. See the table above.
public enum ReadEntryPoint: String, CaseIterable, Sendable {
    case selectionKey
    case articleKey
    case clipboard
    case playClick
}

/// The Reading pane's "When Myna is already reading, the read key…" choice.
/// Stored as a string in the app's defaults so @AppStorage can bind to it.
public enum ReadKeyWhileReading: String, CaseIterable, Identifiable, Sendable {
    case queue
    case interrupt

    public static let defaultsKey = "dev.myna.app.readKeyWhileReading"
    public static let defaultValue: ReadKeyWhileReading = .queue

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .queue: return "Adds to the queue"
        case .interrupt: return "Interrupts"
        }
    }

    /// The saved choice, or the default when none (or an unknown one) is saved.
    public static func current(_ defaults: UserDefaults = .standard) -> ReadKeyWhileReading {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? defaultValue
    }
}

public enum ReadQueuePolicy {
    public static func placement(
        for entry: ReadEntryPoint, preference: ReadKeyWhileReading
    ) -> ReadQueue.Placement {
        switch entry {
        case .playClick:
            return .playNow
        case .selectionKey, .articleKey, .clipboard:
            return preference == .queue ? .queueIfBusy : .playNow
        }
    }
}
