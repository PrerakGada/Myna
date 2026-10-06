// BlendSheet.swift — mix two or three Kokoro voices into one of your own.
//
// Kokoro averages the voice embeddings it is given, so a blend needs no new
// model files: the daemon stores the recipe and sends Kokoro "a,a,a,b" for a
// 3:1 mix. Weights are whole parts (1–4) rather than a slider, because
// that is exactly what the engine can express.
import SwiftUI

struct BlendSheet: View {
    let voices: [Voice]
    /// Creates the blend; returns an error message, or nil when done.
    let onCreate: (String?, [BlendPart]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var parts: [Part]
    @State private var name = ""
    @State private var creating = false
    @State private var errorMessage: String?

    struct Part: Identifiable, Equatable {
        let id = UUID()
        var voice: String
        var weight: Int
    }

    init(voices: [Voice], onCreate: @escaping (String?, [BlendPart]) async -> String?) {
        self.voices = voices
        self.onCreate = onCreate
        let first = voices.first?.id ?? ""
        let second = voices.dropFirst().first?.id ?? first
        _parts = State(initialValue: [Part(voice: first, weight: 1), Part(voice: second, weight: 1)])
    }

    private var totalWeight: Int { parts.reduce(0) { $0 + $1.weight } }
    private var hasDuplicate: Bool { Set(parts.map(\.voice)).count != parts.count }

    private func label(_ id: String) -> String {
        voices.first { $0.id == id }?.label ?? id
    }

    private var suggestedName: String {
        parts.map { label($0.voice) }.joined(separator: " × ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New blend")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DashboardDesign.title)
                Text("Kokoro mixes the voices you pick into a new one. Parts set how much of each: "
                     + "3 and 1 is three parts of the first to one of the second. The blend "
                     + "reads with the first voice's accent.")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashCard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($parts) { $part in
                        HStack(spacing: 10) {
                            Picker("", selection: $part.voice) {
                                ForEach(voices.grouped()) { group in
                                    Section(group.name) {
                                        ForEach(group.voices) { voice in
                                            Text(pickerTitle(voice)).tag(voice.id)
                                        }
                                    }
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                            Stepper(value: $part.weight, in: 1...4) {
                                Text(part.weight == 1 ? "1 part" : "\(part.weight) parts")
                                    .font(DashboardDesign.bodyFont.monospacedDigit())
                                    .foregroundStyle(DashboardDesign.body)
                                    .frame(width: 56, alignment: .leading)
                            }
                            Text(share(part))
                                .font(DashboardDesign.captionFont.monospacedDigit())
                                .foregroundStyle(DashboardDesign.tertiary)
                                .frame(width: 36, alignment: .trailing)
                            if parts.count > 2 {
                                Button {
                                    parts.removeAll { $0.id == part.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DashboardDesign.secondary)
                                .help("Remove this voice from the blend")
                            }
                        }
                    }
                    if parts.count < 3 {
                        Button {
                            let unused = voices.first { v in !parts.contains { $0.voice == v.id } }
                            parts.append(Part(voice: unused?.id ?? parts[0].voice, weight: 1))
                        } label: {
                            Label("Add a third voice", systemImage: "plus")
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            HStack(spacing: 10) {
                Text("Name")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                TextField(suggestedName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if hasDuplicate {
                Text("Each voice can be in the blend once.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.warning)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.negative)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Making…" : "Make blend") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating || hasDuplicate || voices.count < 2)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(DashboardDesign.surface)
    }

    private func pickerTitle(_ voice: Voice) -> String {
        [voice.label, voice.gender?.capitalized, voice.grade.map { "grade \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func share(_ part: Part) -> String {
        guard totalWeight > 0 else { return "" }
        return "\(Int((Double(part.weight) / Double(totalWeight) * 100).rounded()))%"
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mix = parts.map { BlendPart(voice: $0.voice, weight: $0.weight) }
        if let error = await onCreate(trimmed.isEmpty ? nil : trimmed, mix) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}
