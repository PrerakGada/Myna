// VoicesPane.swift — every voice the active engine can speak, and the ones you make.
//
// What there is to choose depends on the engine, so the pane says that
// first instead of showing a lone tile:
//   • Kokoro: 41 built-in voices in six languages, filed by language, each
//     with hexgrad's quality grade — plus blends you mix from them.
//   • Pocket TTS and Chatterbox: their built-in voices plus any voice copied
//     from a recording. Import one, drop one on the pane, or pick one of the
//     113 in the voice library.
//   • Soprano: one voice. The pane says why and points to the Engine screen.
//
// Each tile shows how often you have used the voice, which is what helps
// when choosing between voices that all sound plausible in a short sample.
// Preview orchestration (ducking, debounce, "engine warming" on a 503) is
// VoicePreviewService's, shared with the library sheet.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum GenderFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case female = "Female"
    case male = "Male"

    var id: String { rawValue }

    func matches(_ gender: String?) -> Bool {
        switch self {
        case .all: return true
        case .female: return gender == "female"
        case .male: return gender == "male"
        }
    }
}

struct VoicesPane: View {
    let client: DaemonClient
    @ObservedObject var settings: SettingsViewModel
    let player: AudioPlayer
    @ObservedObject var history: HistoryStore
    let onOpenEngines: () -> Void

    @State private var response: VoicesResponse?
    @State private var refreshing = false
    @State private var errorMessage: String?
    @State private var search = ""
    @State private var gender: GenderFilter = .all
    @State private var showLibrary = false
    @State private var showBlend = false
    @State private var importing = false
    @State private var notice: (text: String, isError: Bool)?
    @State private var renaming: Voice?
    @State private var renameText = ""
    @State private var confirmDelete: Voice?
    @State private var dropTargeted = false
    @StateObject private var preview: VoicePreviewService

    init(
        client: DaemonClient,
        settings: SettingsViewModel,
        player: AudioPlayer,
        history: HistoryStore,
        onOpenEngines: @escaping () -> Void
    ) {
        self.client = client
        self.settings = settings
        self.player = player
        self.history = history
        self.onOpenEngines = onOpenEngines
        _preview = StateObject(
            wrappedValue: VoicePreviewService(client: client, sink: player))
    }

    private var voices: [Voice] { response?.voices ?? [] }
    private var about: VoicesEngineInfo? { response?.activeEngine }
    private var builtIns: [Voice] { voices.filter { !$0.isUserMade } }
    private var canClone: Bool { about?.canClone ?? false }
    private var selectedId: String? { voices.effectiveVoiceId(saved: settings.voice) }
    private var hasGenders: Bool { voices.contains { $0.gender != nil } }

    private var filtered: [Voice] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return voices.filter { voice in
            guard gender.matches(voice.gender) else { return false }
            guard !query.isEmpty else { return true }
            return [voice.label, voice.group ?? "", voice.detail ?? "", voice.id]
                .contains { $0.lowercased().contains(query) }
        }
    }

    /// Reads per voice across all history — drives the "used N times" line.
    private var usage: [String: Int] {
        Dictionary(history.events.map { ($0.voice, 1) }, uniquingKeysWith: +)
    }

    var body: some View {
        PaneScaffold(
            title: DashboardPane.voices.title,
            subtitle: DashboardPane.voices.subtitle
        ) {
            Button {
                Task { await refresh() }
            } label: {
                Label(refreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(refreshing)
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                if let errorMessage {
                    DashCard {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(DashboardDesign.bodyFont)
                            .foregroundStyle(DashboardDesign.negative)
                    }
                }
                if about != nil {
                    engineCard
                }
                if voices.count > 8 {
                    filterBar
                }
                voiceSections
                playbackCard
            }
        }
        .overlay { dropOverlay }
        .dropDestination(for: URL.self) { urls, _ in
            guard canClone, let url = urls.first else { return false }
            Task { await importRecording(url) }
            return true
        } isTargeted: { dropTargeted = $0 && canClone }
        .task { await refresh() }
        .onDisappear { preview.cancel() }
        .sheet(isPresented: $showLibrary) {
            VoiceLibrarySheet(
                client: client,
                settings: settings,
                preview: preview,
                engineName: about?.name ?? "This engine",
                onChanged: { Task { await refresh() } }
            )
        }
        .sheet(isPresented: $showBlend) {
            BlendSheet(voices: builtIns) { name, mix in
                await createBlend(name: name, mix: mix)
            }
        }
        .alert(
            "Rename voice",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { voice in
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await rename(voice) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(confirmDelete?.label ?? "")”?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { voice in
            Button("Delete", role: .destructive) { Task { await delete(voice) } }
        } message: { voice in
            Text(voice.kind == "clip"
                ? "Its recording is removed from this Mac. Anything set to use it goes back to "
                    + "the engine's default voice."
                : "Anything set to use it goes back to the engine's default voice.")
        }
    }

}

// MARK: - What the engine offers, filters, the voice grid

extension VoicesPane {

    private var engineCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(about?.name ?? "")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DashboardDesign.title)
                    Text(voiceCountLine)
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.secondary)
                    Spacer(minLength: 8)
                    Button("Change engine…", action: onOpenEngines)
                        .buttonStyle(.link)
                }
                Text(capabilityLine)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                    .fixedSize(horizontal: false, vertical: true)
                if about?.canClone == true || about?.canBlend == true {
                    HStack(spacing: 8) {
                        if about?.canClone == true {
                            Button {
                                showLibrary = true
                            } label: {
                                Label("Voice library…", systemImage: "books.vertical")
                            }
                            Button {
                                chooseRecording()
                            } label: {
                                Label(importing ? "Adding…" : "Add a recording…", systemImage: "waveform.badge.plus")
                            }
                            .disabled(importing)
                        }
                        if about?.canBlend == true {
                            Button {
                                showBlend = true
                            } label: {
                                Label("New blend…", systemImage: "slider.horizontal.3")
                            }
                            .disabled(builtIns.count < 2)
                        }
                    }
                }
                if let notice {
                    Text(notice.text)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(notice.isError ? DashboardDesign.negative : DashboardDesign.positive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var voiceCountLine: String {
        let own = voices.count - builtIns.count
        let languages = Set(builtIns.map(\.lang)).count
        var parts: [String] = [builtIns.count == 1 ? "1 voice" : "\(builtIns.count) voices"]
        if languages > 1 { parts[0] += " in \(languages) languages" }
        if own > 0 { parts.append("\(own) of your own") }
        return parts.joined(separator: " · ")
    }

    private var capabilityLine: String {
        if let note = about?.note { return note }
        if about?.canClone == true {
            return "It can also speak in any voice from a recording: 6 to 20 seconds of one person "
                + "talking clearly. Add your own, drop an audio file on this screen, or pick one "
                + "from the library."
        }
        if about?.canBlend == true {
            return "Grades are hexgrad's estimate of each voice's quality, A best. Mix two or three "
                + "voices into a blend of your own. A voice in another language reads text written "
                + "in that language."
        }
        return ""
    }

    // MARK: filters

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DashboardDesign.tertiary)
                TextField("Search voices", text: $search)
                    .textFieldStyle(.plain)
                    .font(DashboardDesign.bodyFont)
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DashboardDesign.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(DashboardDesign.border, lineWidth: 1)
            )
            if hasGenders {
                Picker("", selection: $gender) {
                    ForEach(GenderFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            Spacer(minLength: 8)
            if filtered.count != voices.count {
                Text("\(filtered.count) of \(voices.count)")
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.tertiary)
            }
        }
    }

    // MARK: voices

    @ViewBuilder
    private var voiceSections: some View {
        if voices.isEmpty {
            DashCard {
                DashEmptyState(
                    systemImage: "waveform",
                    title: refreshing ? "Loading voices…" : "No voices available",
                    message: refreshing
                        ? "Asking the local engine what it can speak."
                        : "The voice engine did not answer. Check it on the Engine screen, "
                            + "then refresh."
                )
            }
        } else if filtered.isEmpty {
            DashCard {
                DashEmptyState(
                    systemImage: "magnifyingglass",
                    title: "No voices match",
                    message: "Nothing matches “\(search)” with \(gender.rawValue.lowercased()) voices. "
                        + "Clear the search or choose All."
                )
            }
        } else {
            ForEach(filtered.grouped()) { group in
                section(group)
            }
        }
    }

    private func section(_ group: VoiceGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DashSectionTitle(group.name)
                Text("\(group.voices.count)")
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.tertiary)
                if let hint = hint(for: group) {
                    Text(hint)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                }
            }
            let columns = [GridItem(.adaptive(minimum: 230), spacing: DashboardDesign.gridSpacing)]
            LazyVGrid(columns: columns, spacing: DashboardDesign.gridSpacing) {
                ForEach(group.voices) { voice in
                    VoiceCard(
                        voice: voice,
                        isSelected: selectedId == voice.id,
                        previewState: preview.state,
                        uses: usage[voice.id] ?? 0,
                        onSelect: { settings.voice = voice.id },
                        onPreview: { preview.preview(voiceId: voice.id) },
                        onRename: voice.isUserMade ? {
                            renameText = voice.label
                            renaming = voice
                        } : nil,
                        onDelete: voice.isUserMade ? { confirmDelete = voice } : nil
                    )
                }
            }
        }
        .padding(.top, 4)
    }

    /// A voice in another language only sounds right reading that language.
    private func hint(for group: VoiceGroup) -> String? {
        guard !group.isUserMade, let lang = group.voices.first?.lang, lang != "en" else { return nil }
        return "For text written in \(group.name)"
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(DashboardDesign.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(DashboardDesign.accent.opacity(0.06))
                .overlay {
                    Label("Drop to copy this voice", systemImage: "waveform.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DashboardDesign.title)
                }
                .padding(12)
                .allowsHitTesting(false)
        }
    }

    private var playbackCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 4) {
                DashSectionTitle("Playback")
                DashRow(
                    "Default speed",
                    help: "Applied to every new read. The popover's speed chips change the "
                        + "current read only."
                ) {
                    HStack(spacing: 10) {
                        Slider(value: $settings.defaultSpeed, in: 0.5...2.0, step: 0.05)
                            .frame(width: 200)
                        Text(String(format: "%.2f×", settings.defaultSpeed))
                            .font(DashboardDesign.bodyFont.monospacedDigit())
                            .foregroundStyle(DashboardDesign.body)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                DashDivider()
                DashRow(
                    "Buffer before playing",
                    help: "Collects a few seconds of audio before starting, so a long read never "
                        + "stalls mid-sentence. Turn off to start sooner."
                ) {
                    Toggle("", isOn: $settings.oneShotPlayback)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

}

// MARK: - Actions

extension VoicesPane {

    private func refresh() async {
        refreshing = true
        errorMessage = nil
        defer { refreshing = false }
        do {
            response = try await client.voiceList()
        } catch {
            errorMessage = "Could not load voices: \(error)"
        }
    }

    private func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a recording of one person speaking clearly, at least 6 seconds long."
        panel.prompt = "Copy Voice"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importRecording(url) }
    }

    private func importRecording(_ url: URL) async {
        importing = true
        notice = nil
        defer { importing = false }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let clip = try await Task.detached(priority: .userInitiated) {
                try ClipImporter.clip(from: url)
            }.value
            let voice = try await client.addClipVoice(wav: clip.wav, name: name)
            settings.voice = voice.id
            let cut = clip.trimmed
                ? " Only its first \(Int(ClipImporter.maximumSeconds)) seconds are used." : ""
            notice = ("Added “\(voice.label)” and switched to it.\(cut)", false)
            await refresh()
        } catch {
            notice = (error.localizedDescription, true)
        }
    }

    /// Returns an error message for the sheet to show, or nil when done.
    private func createBlend(name: String?, mix: [BlendPart]) async -> String? {
        do {
            let voice = try await client.addBlendVoice(name: name, mix: mix)
            settings.voice = voice.id
            notice = ("Made “\(voice.label)” and switched to it.", false)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func rename(_ voice: Voice) async {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != voice.label else { return }
        do {
            _ = try await client.renameVoice(id: voice.id, name: name)
            await refresh()
        } catch {
            notice = (error.localizedDescription, true)
        }
    }

    private func delete(_ voice: Voice) async {
        do {
            try await client.deleteVoice(id: voice.id)
            await refresh()
            if settings.voice == voice.id, let fallback = voices.effectiveVoiceId(saved: nil) {
                settings.voice = fallback
            }
            notice = ("Deleted “\(voice.label)”.", false)
        } catch {
            notice = (error.localizedDescription, true)
        }
    }
}
