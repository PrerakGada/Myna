// PronunciationEditor.swift — the sheet that adds or edits one
// pronunciation, and the "Fix pronunciation…" sheet History opens with the
// read's own words to pick from.
import SwiftUI

struct PronunciationEditorSheet: View {
    let title: String
    /// Words to pick from (a History read's), or empty.
    let wordChoices: [String]
    @ObservedObject var tester: PronunciationTester
    /// Saves; returns the daemon's refusal to show, or nil when saved.
    let onSave: (_ word: String, _ say: String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var word: String
    @State private var say: String
    @State private var error: String?
    @State private var saving = false

    init(
        title: String,
        word: String = "",
        say: String = "",
        wordChoices: [String] = [],
        tester: PronunciationTester,
        onSave: @escaping (_ word: String, _ say: String) async -> String?
    ) {
        self.title = title
        self.wordChoices = wordChoices
        self.tester = tester
        self.onSave = onSave
        _word = State(initialValue: word)
        _say = State(initialValue: say)
    }

    private var trimmedWord: String { word.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSay: String { say.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visibleChoices: [String] {
        let needle = trimmedWord.lowercased()
        let matching = needle.isEmpty ? wordChoices : wordChoices.filter { $0.lowercased().contains(needle) }
        return Array(matching.prefix(60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Word or phrase").font(DashboardDesign.captionFont).foregroundStyle(.secondary)
                TextField("kubectl", text: $word)
                    .textFieldStyle(.roundedBorder)
                if !wordChoices.isEmpty {
                    Text("Or pick one from this read:")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(.secondary)
                    wordPicker
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Say it as").font(DashboardDesign.captionFont).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("cube control", text: $say)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        tester.play(trimmedSay, key: "editor")
                    } label: {
                        if tester.loadingKey == "editor" {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Test", systemImage: "play.fill")
                        }
                    }
                    .disabled(trimmedSay.isEmpty)
                    .help("Hear the respelling in your current voice")
                }
                Text(
                    "Spell it the way it sounds, in ordinary letters. Capitals are read as letters "
                        + "(“S Q L”). It replaces the whole word wherever it appears, in any case."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let message = error ?? tester.failure {
                Text(message)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    tester.stop()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedWord.isEmpty || trimmedSay.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var wordPicker: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(visibleChoices, id: \.self) { choice in
                    Button {
                        word = choice
                    } label: {
                        Text(choice)
                            .font(DashboardDesign.captionFont)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(choice == trimmedWord ? DashboardDesign.accent.opacity(0.3) : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 130)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let refusal = await onSave(trimmedWord, trimmedSay) {
            error = refusal
        } else {
            tester.stop()
            dismiss()
        }
    }
}

/// History's "Fix pronunciation…": the editor, with the read's words to
/// pick from, saving straight to the daemon's list.
struct PronunciationFixSheet: View {
    let words: [String]
    @StateObject private var model: PronunciationModel
    @StateObject private var tester: PronunciationTester

    init(baseURL: URL, text: String) {
        words = PronunciationWords.candidates(in: text)
        _model = StateObject(wrappedValue: PronunciationModel(client: PronunciationClient(baseURL: baseURL)))
        _tester = StateObject(wrappedValue: PronunciationTester(client: RenderClient(baseURL: baseURL)))
    }

    var body: some View {
        PronunciationEditorSheet(
            title: "Fix a pronunciation",
            wordChoices: words,
            tester: tester
        ) { word, say in
            await model.add(word: word, say: say)
        }
    }
}
