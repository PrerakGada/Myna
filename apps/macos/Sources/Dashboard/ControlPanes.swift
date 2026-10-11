// ControlPanes.swift — Shortcuts, Reading, Gestures and App Voices.
//
// These four replace the Hotkeys / Behavior / Gestures / Wardrobe tabs of
// the old Settings window. They bind to exactly the same
// SettingsViewModel and KeyboardShortcuts storage — no preference is
// duplicated and none is orphaned — but they lay out at the Dashboard's
// width instead of each pinning itself to its own 460×360 box.
import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsPane: View {
    private struct Row: Identifiable {
        let label: String
        let help: String
        let name: KeyboardShortcuts.Name
        var id: KeyboardShortcuts.Name { name }
    }

    private let rows: [Row] = [
        .init(
            label: "Speak selection",
            help: "Reads whatever text is selected in the frontmost app.",
            name: .speakSelectionFull),
        .init(
            label: "Speak a summary",
            help: "Summarises the selection first, then reads the summary.",
            name: .speakSelectionSummary),
        .init(
            label: "Read the Chrome article",
            help: "Extracts the article from the front Chrome tab and reads it.",
            name: .readChromeArticle),
        .init(
            label: "Pause / resume",
            help: "Toggles the current read.",
            name: .pauseResume),
        .init(
            label: "Stop",
            help: "Stops immediately and clears the queue.",
            name: .stop),
        .init(
            label: "Skip to the next read",
            help: "Ends the current read and starts the next one in the queue. No chord by default.",
            name: .skipToNext),
        .init(
            label: "Previous sentence",
            help: "Back to the start of this sentence, or the one before if it has only just begun. "
                + "No chord by default.",
            name: .previousSentence),
        .init(
            label: "Next sentence",
            help: "Skips ahead one sentence in the current read. No chord by default.",
            name: .nextSentence),
    ]

    var body: some View {
        PaneScaffold(
            title: DashboardPane.shortcuts.title,
            subtitle: DashboardPane.shortcuts.subtitle
        ) {
            Button("Reset to defaults") {
                KeyboardShortcuts.reset(KeyboardShortcuts.Name.allMynaShortcuts)
            }
            .help("Restore every Myna shortcut to its original chord.")
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                DashCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            DashRow(row.label, help: row.help) {
                                ShortcutRecorderView(name: row.name)
                                    .fixedSize()
                            }
                            if index < rows.count - 1 { DashDivider() }
                        }
                    }
                }
                DashCard {
                    VStack(alignment: .leading, spacing: 6) {
                        DashSectionTitle("How recording works")
                        Text(
                            "Click a recorder and press the chord you want. Delete clears an "
                                + "action; Escape cancels. Pasting text into a recorder is blocked "
                                + "on purpose — a pasted chord never fires."
                        )
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "Myna needs Accessibility permission to read a selection with a "
                                + "shortcut. Without it the shortcut fires and nothing plays; "
                                + "Services ▸ Read with Myna still works."
                        )
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Open Accessibility settings") {
                            let path =
                                "x-apple.systempreferences:com.apple.preference.security"
                                + "?Privacy_Accessibility"
                            if let url = URL(string: path) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Reading

struct ReadingPane: View {
    @ObservedObject var settings: SettingsViewModel
    @AppStorage("dev.myna.app.showFloatingPill") private var showFloatingPill: Bool = true

    var body: some View {
        PaneScaffold(
            title: DashboardPane.reading.title,
            subtitle: DashboardPane.reading.subtitle
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                SelectionCaptureCard(settings: settings)
                ReadQueueSettingsCard()
                TranscriptSettingsCard()
                SummariesCard()
                DashCard {
                    VStack(alignment: .leading, spacing: 0) {
                        DashSectionTitle("Floating pill")
                            .padding(.bottom, 6)
                        DashRow(
                            "Show the pill while speaking",
                            help: "A small chip at the bottom of the active display. Hover to "
                                + "expand it into a mini player."
                        ) {
                            Toggle("", isOn: $showFloatingPill)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        DashDivider()
                        DashRow(
                            "Keep it always visible",
                            help: "Stays on screen even when nothing is playing. Drag it anywhere "
                                + "and Myna remembers where you put it."
                        ) {
                            Toggle("", isOn: $settings.pillAlwaysVisible)
                                .labelsHidden().toggleStyle(.switch)
                                .disabled(!showFloatingPill)
                        }
                        DashDivider()
                        DashRow(
                            "Live captions",
                            help: "While Myna reads, the pill opens to show the sentence being read, "
                                + "with the spoken word lit. Reads from Claude Code's Myna controls too."
                        ) {
                            Toggle("", isOn: $settings.pillLiveCaptions)
                                .labelsHidden().toggleStyle(.switch)
                                .disabled(!showFloatingPill)
                        }
                        DashDivider()
                        DashRow("Reset the pill's position") {
                            Button("Reset") {
                                NotificationCenter.default.post(
                                    name: PillController.resetPositionNotification, object: nil)
                            }
                            .disabled(!showFloatingPill)
                        }
                    }
                }

                TextCleanupCard(settings: settings)

                DashCard {
                    VStack(alignment: .leading, spacing: 0) {
                        DashSectionTitle("Claude Code")
                            .padding(.bottom, 6)
                        DashRow(
                            "Announce when Claude finishes",
                            help: "A finished session's reply appears in the pill with Play and "
                                + "Dismiss. With the pill off, a card slides in at the top-right."
                        ) {
                            Toggle("", isOn: $settings.ccToastsEnabled)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        DashDivider()
                        DashRow("Chime when that card appears") {
                            Toggle("", isOn: $settings.toastChimeEnabled)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        DashDivider()
                        DashRow(
                            "Read only the bold claims",
                            help: "Play just the bold sentences of a reply — the gist, when "
                                + "Claude bolds its key claims. A reply with no bold is read in full."
                        ) {
                            Toggle("", isOn: $settings.ccBoldClaimsOnly)
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

                ClaudeHandsFreeCard()

                DashCard {
                    VStack(alignment: .leading, spacing: 0) {
                        DashSectionTitle("Sounds")
                            .padding(.bottom, 6)
                        DashRow(
                            "Tone when a trackpad gesture lands",
                            help: "A 55 ms rising tone (660→880 Hz) at −14 dB, the moment the "
                                + "gesture registers — so you know it took, without waiting for "
                                + "speech."
                        ) {
                            Toggle("", isOn: $settings.gestureEarconEnabled)
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Gestures

struct GesturesPane: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        PaneScaffold(
            title: DashboardPane.gestures.title,
            subtitle: DashboardPane.gestures.subtitle
        ) {
            Toggle("", isOn: $settings.trackpadGesturesEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Trackpad gestures are off by default.")
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                DashCard {
                    VStack(alignment: .leading, spacing: 0) {
                        DashSectionTitle("Four-finger gestures")
                            .padding(.bottom, 6)
                        DashRow(
                            "Press and hold",
                            help: "Rest four fingers for about a third of a second. The most "
                                + "reliable trigger."
                        ) {
                            Text("Read selection").foregroundStyle(DashboardDesign.secondary)
                        }
                        DashDivider()
                        DashRow("Tap", help: "A brief four-finger touch, then lift.") {
                            Text("Read selection").foregroundStyle(DashboardDesign.secondary)
                        }
                        DashDivider()
                        DashRow(
                            "Double-tap",
                            help: "A second tap within the system double-click interval."
                        ) {
                            Text("Stop").foregroundStyle(DashboardDesign.secondary)
                        }
                    }
                    .opacity(settings.trackpadGesturesEnabled ? 1 : 0.45)
                }

                DashCard {
                    VStack(alignment: .leading, spacing: 10) {
                        DashSectionTitle("Known limitations")
                        LimitationRow(
                            headline: "Conflicts with BetterTouchTool and other multitouch tools.",
                            detail: Self.conflictBody)
                        LimitationRow(
                            headline: "Needs a built-in or Magic Trackpad.",
                            detail: Self.trackpadBody)
                        LimitationRow(
                            headline: "Uses a private macOS framework.",
                            detail: Self.privateAPIBody)
                    }
                }
            }
        }
    }

    // Long prose kept as constants: the CI compiler refuses to type-check
    // chained string concatenation inside a ViewBuilder (see GesturesTab).
    // swiftlint:disable line_length
    static let conflictBody = """
BTT, Magnet, Cinch and similar tools subscribe to the same MultitouchSupport contact-frame callback. Only one app reliably receives the events — usually whichever started first. If gestures aren't firing, quit those apps and toggle Myna's gestures off and on once to re-subscribe.
"""
    static let trackpadBody = """
External mice and most Bluetooth keyboards' trackpads are not detected. The switch stays on but no gesture ever fires.
"""
    static let privateAPIBody = """
Public NSEvent APIs don't expose finger counts for global gestures, so Myna reads them from Apple's MultitouchSupport framework — the same one BetterTouchTool, Magnet and Hammerspoon have used for 15+ years. If Apple removes it, gestures stop and Myna falls back to shortcuts.
"""
    // swiftlint:enable line_length
}

private struct LimitationRow: View {
    let headline: String
    /// Named `detail`, not `body` — a stored `body` collides with View's.
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("• " + headline)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.body)
            Text(detail)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
        }
    }
}

// MARK: - App voices (wardrobe)

struct WardrobePane: View {
    let client: DaemonClient
    @StateObject private var store: VoiceWardrobeStore
    @State private var voices: [Voice] = []
    @State private var newBundleId: String = ""
    @State private var newVoiceId: String = ""

    init(client: DaemonClient) {
        self.client = client
        _store = StateObject(wrappedValue: VoiceWardrobeStore(client: client))
    }

    private var sortedBundleIds: [String] {
        store.mappings.keys.sorted()
    }

    var body: some View {
        PaneScaffold(
            title: DashboardPane.wardrobe.title,
            subtitle: DashboardPane.wardrobe.subtitle
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                DashCard {
                    VStack(alignment: .leading, spacing: 0) {
                        DashSectionTitle("Current mappings")
                            .padding(.bottom, 8)
                        if store.isLoading && store.mappings.isEmpty {
                            Text("Loading…")
                                .font(DashboardDesign.bodyFont)
                                .foregroundStyle(DashboardDesign.secondary)
                        } else if store.mappings.isEmpty {
                            Text(
                                "No app-specific voices yet. Everything uses your default voice."
                            )
                            .font(DashboardDesign.bodyFont)
                            .foregroundStyle(DashboardDesign.secondary)
                        } else {
                            ForEach(Array(sortedBundleIds.enumerated()), id: \.element) { index, bundleId in
                                HStack(spacing: 12) {
                                    Text(bundleId)
                                        .font(DashboardDesign.bodyFont)
                                        .foregroundStyle(DashboardDesign.body)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Picker("", selection: voiceBinding(for: bundleId)) {
                                        voiceOptions
                                    }
                                    .labelsHidden()
                                    .frame(width: 170)
                                    Button {
                                        Task { await store.remove(bundleId: bundleId) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(DashboardDesign.tertiary)
                                    .help("Remove this mapping")
                                }
                                .padding(.vertical, 7)
                                if index < sortedBundleIds.count - 1 { DashDivider() }
                            }
                        }
                    }
                }

                DashCard {
                    VStack(alignment: .leading, spacing: 10) {
                        DashSectionTitle("Add a mapping")
                        HStack(spacing: 10) {
                            TextField("Bundle ID (e.g. com.apple.Safari)", text: $newBundleId)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $newVoiceId) {
                                Text("Choose a voice").tag("")
                                voiceOptions
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            Button("Add") {
                                let bundle = newBundleId.trimmingCharacters(in: .whitespaces)
                                guard !bundle.isEmpty, !newVoiceId.isEmpty else { return }
                                Task {
                                    await store.set(bundleId: bundle, voiceId: newVoiceId)
                                    newBundleId = ""
                                    newVoiceId = ""
                                }
                            }
                            .disabled(
                                newBundleId.trimmingCharacters(in: .whitespaces).isEmpty
                                    || newVoiceId.isEmpty)
                        }
                        Text(
                            "Not sure of a bundle ID? Running apps are listed below — click one to "
                                + "fill it in."
                        )
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        RunningAppPicker { bundleId in newBundleId = bundleId }
                    }
                }
            }
        }
        .task {
            voices = (try? await client.voices()) ?? []
            await store.refresh()
        }
    }

    /// Filed like every other voice picker: the user's own first, then
    /// the engine's groups (Kokoro alone has seven languages).
    @ViewBuilder
    private var voiceOptions: some View {
        ForEach(voices.grouped()) { group in
            Section(group.name) {
                ForEach(group.voices) { voice in
                    Text(voice.label).tag(voice.id)
                }
            }
        }
    }

    private func voiceBinding(for bundleId: String) -> Binding<String> {
        Binding(
            get: { store.mappings[bundleId] ?? "" },
            set: { newValue in
                Task { await store.set(bundleId: bundleId, voiceId: newValue) }
            }
        )
    }
}

/// Chips for every running app with a bundle id — removes the "go and
/// find the bundle identifier yourself" step the old Settings tab left
/// to the user.
private struct RunningAppPicker: View {
    let onPick: (String) -> Void

    private var apps: [(name: String, bundleId: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleId = app.bundleIdentifier,
                    let name = app.localizedName
                else { return nil }
                return (name, bundleId)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(apps, id: \.bundleId) { app in
                Button {
                    onPick(app.bundleId)
                } label: {
                    Text(app.name)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.body)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help(app.bundleId)
            }
        }
    }
}
