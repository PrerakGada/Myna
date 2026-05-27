// VoiceWardrobeView.swift — Settings tab that lists the per-bundle-id
// voice overrides and lets the user add/remove them.
//
// Low-fidelity by design: a list of (bundle_id, voice_id) rows with
// inline edit + delete. The "add" controls live below the list. We
// pull the voice list from the daemon so dropdowns show real, current
// voice options.
import os
import SwiftUI

public struct VoiceWardrobeView: View {
    @StateObject private var store: VoiceWardrobeStore
    @State private var voices: [Voice] = []
    @State private var newBundleId: String = ""
    @State private var newVoiceId: String = ""

    private let client: DaemonClient

    public init(client: DaemonClient) {
        self.client = client
        _store = StateObject(wrappedValue: VoiceWardrobeStore(client: client))
    }

    public var body: some View {
        Form {
            Section {
                Text(
                    "Pick a voice for each app. The frontmost app's voice "
                    + "is used automatically when you trigger a TTS hotkey."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Current mappings") {
                if store.isLoading && store.mappings.isEmpty {
                    Text("Loading…").foregroundStyle(.secondary)
                } else if store.mappings.isEmpty {
                    Text("No app-specific voices yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedBundleIds, id: \.self) { bundleId in
                        WardrobeRow(
                            bundleId: bundleId,
                            currentVoiceId: store.mappings[bundleId] ?? "",
                            voices: voices,
                            onChange: { newVoice in
                                Task { await store.set(bundleId: bundleId, voiceId: newVoice) }
                            },
                            onRemove: {
                                Task { await store.remove(bundleId: bundleId) }
                            }
                        )
                    }
                }
            }

            Section("Add mapping") {
                TextField("Bundle ID (e.g. com.apple.Safari)", text: $newBundleId)
                Picker("Voice", selection: $newVoiceId) {
                    Text("Pick a voice…").tag("")
                    ForEach(voices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                Button("Add") {
                    let bundle = newBundleId.trimmingCharacters(in: .whitespaces)
                    let voice = newVoiceId.trimmingCharacters(in: .whitespaces)
                    guard !bundle.isEmpty, !voice.isEmpty else { return }
                    Task {
                        await store.set(bundleId: bundle, voiceId: voice)
                        newBundleId = ""
                        newVoiceId = ""
                    }
                }
                .disabled(
                    newBundleId.trimmingCharacters(in: .whitespaces).isEmpty
                    || newVoiceId.isEmpty
                )
            }

            if let err = store.lastError {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .frame(width: 460, height: 380)
        .task {
            await store.refresh()
            await loadVoices()
        }
    }

    private var sortedBundleIds: [String] {
        store.mappings.keys.sorted()
    }

    private func loadVoices() async {
        do {
            voices = try await client.voices()
        } catch {
            Log(.network).error("VoiceWardrobeView voice load failed: \(error)")
        }
    }
}

/// One row in the wardrobe table. Letting users change the voice
/// in-line is the obvious affordance; remove is a button on the trailing
/// edge so the row stays compact.
private struct WardrobeRow: View {
    let bundleId: String
    let currentVoiceId: String
    let voices: [Voice]
    let onChange: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Text(bundleId)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: Binding(
                get: { currentVoiceId },
                set: { onChange($0) }
            )) {
                if voices.isEmpty {
                    Text(currentVoiceId).tag(currentVoiceId)
                } else {
                    ForEach(voices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this mapping")
        }
    }
}
