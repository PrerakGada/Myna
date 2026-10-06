// VoiceLibrarySheet.swift — ready-made voices for the engines that copy one.
//
// 113 recordings of real people from Kyutai's tts-voices collection, all
// licensed for use in Myna: speakers from the VCTK corpus (English accents
// from Edinburgh to Toronto to Johannesburg, filed by accent with age and
// gender from the corpus), a voice actor's characters, and audiobook
// narrators. ▶ plays the original recording, which is what a copied voice
// aims for; Add downloads it (~1 MB) into your voices.
import SwiftUI

struct VoiceLibrarySheet: View {
    let client: DaemonClient
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var preview: VoicePreviewService
    let engineName: String
    /// Called after a voice is added, so the Voices screen refreshes.
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var library: VoiceLibraryResponse?
    @State private var loadError: String?
    @State private var search = ""
    @State private var group = Self.allGroups
    @State private var gender: GenderFilter = .all
    @State private var adding: String?
    @State private var rowError: (id: String, message: String)?

    private static let allGroups = "All accents"

    private var entries: [LibraryVoice] { library?.voices ?? [] }

    private var groups: [String] {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.group) { seen.append(entry.group) }
        return seen
    }

    private var filtered: [LibraryVoice] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            (group == Self.allGroups || entry.group == group)
                && gender.matches(entry.gender)
                && (query.isEmpty
                    || [entry.name, entry.group, entry.detail].contains { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice library")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DashboardDesign.title)
                Text("\(entries.isEmpty ? "Recordings" : "\(entries.count) recordings") of real people, "
                     + "licensed for use in Myna. Add one and \(engineName) speaks in that voice. "
                     + "▶ plays the original recording; the copy will be close, not identical.")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            filters

            if let loadError {
                DashCard {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.negative)
                }
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                        if index < filtered.count - 1 { DashDivider() }
                    }
                }
                .padding(.horizontal, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                    .fill(DashboardDesign.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                    .strokeBorder(DashboardDesign.border, lineWidth: 1)
            )

            HStack(alignment: .bottom) {
                Text("From Kyutai's tts-voices collection: the CSTR VCTK Corpus, University of "
                     + "Edinburgh (CC BY 4.0); Alba MacKenna (CC BY 4.0); LibriVox narrators via "
                     + "Voice-Zero (CC0).")
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardDesign.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 760, height: 620)
        .background(DashboardDesign.surface)
        .task { await load() }
        .onDisappear { preview.cancel() }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            TextField("Search by place or accent", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Picker("", selection: $group) {
                Text(Self.allGroups).tag(Self.allGroups)
                Divider()
                ForEach(groups, id: \.self) { name in
                    Text("\(name) (\(entries.filter { $0.group == name }.count))").tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            Picker("", selection: $gender) {
                ForEach(GenderFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            Spacer(minLength: 0)
            Text("\(filtered.count)")
                .font(DashboardDesign.captionFont.monospacedDigit())
                .foregroundStyle(DashboardDesign.tertiary)
        }
    }

    private func row(_ entry: LibraryVoice) -> some View {
        let sampleId = VoicePreviewService.librarySampleId(entry.id)
        return HStack(spacing: 12) {
            Button {
                preview.previewLibrarySample(id: entry.id)
            } label: {
                Image(systemName: isBusy(sampleId) ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isBusy(sampleId) ? DashboardDesign.accent : DashboardDesign.secondary)
            }
            .buttonStyle(.plain)
            .help("Hear the original recording")
            .accessibilityLabel("Play \(entry.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DashboardDesign.title)
                Text(facts(entry))
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                if let note = note(for: entry, sampleId: sampleId) {
                    Text(note.text)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(note.isError ? DashboardDesign.negative : DashboardDesign.warning)
                }
            }
            .help(entry.credit)

            Spacer(minLength: 8)
            action(entry)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func action(_ entry: LibraryVoice) -> some View {
        if let voiceId = entry.addedAs {
            if settings.voice == voiceId {
                DashBadge("Active", tint: DashboardDesign.accent)
            } else {
                Button("Use") { settings.voice = voiceId }
                    .help("Make \(entry.name) the voice Myna reads with")
            }
        } else {
            Button(adding == entry.id ? "Adding…" : "Add") {
                Task { await add(entry) }
            }
            .disabled(adding != nil)
            .help("Download this recording (\(entry.sizeKb / 1024 + 1) MB) and add it to your voices")
        }
    }

    private func facts(_ entry: LibraryVoice) -> String {
        var facts: [String] = []
        if let gender = entry.gender {
            facts.append(entry.age.map { "\(gender.capitalized), \($0)" } ?? gender.capitalized)
        }
        facts.append(entry.detail)
        return facts.joined(separator: " · ")
    }

    private func isBusy(_ sampleId: String) -> Bool {
        switch preview.state {
        case .loading(let id), .playing(let id): return id == sampleId
        default: return false
        }
    }

    private func note(for entry: LibraryVoice, sampleId: String) -> (text: String, isError: Bool)? {
        if let rowError, rowError.id == entry.id { return (rowError.message, true) }
        if case .failed(let id, _) = preview.state, id == sampleId {
            return ("Couldn't play the recording. Check the internet connection.", true)
        }
        if case .loading(let id) = preview.state, id == sampleId {
            return ("Downloading…", false)
        }
        return nil
    }

    private func load() async {
        do {
            library = try await client.voiceLibrary()
            loadError = nil
        } catch {
            loadError = "Couldn't load the voice library: \(error.localizedDescription)"
        }
    }

    private func add(_ entry: LibraryVoice) async {
        adding = entry.id
        rowError = nil
        defer { adding = nil }
        do {
            _ = try await client.addLibraryVoice(id: entry.id)
            await load()
            onChanged()
        } catch {
            rowError = (entry.id, error.localizedDescription)
        }
    }
}
