// PronunciationPane.swift — words Myna should say differently.
//
// Two lists, both applied by the daemon after text cleanup on every read
// and render: the user's own words, and a starter list of tech words the
// engines get wrong (switchable as a whole or one by one; a word of your
// own wins over the starter's). Each row's ▶ plays the respelling in the
// current voice. The daemon owns the list (/v2/pronunciations).
import SwiftUI

struct PronunciationPane: View {
    @StateObject private var model: PronunciationModel
    @StateObject private var tester: PronunciationTester
    @State private var query = ""
    @State private var editing: EditTarget?

    private enum EditTarget: Identifiable {
        case new
        case entry(PronunciationEntry)
        case starter(StarterPronunciation)

        var id: String {
            switch self {
            case .new: return "new"
            case .entry(let entry): return entry.id
            case .starter(let entry): return "starter-" + entry.id
            }
        }
    }

    init(baseURL: URL) {
        _model = StateObject(wrappedValue: PronunciationModel(client: PronunciationClient(baseURL: baseURL)))
        _tester = StateObject(wrappedValue: PronunciationTester(client: RenderClient(baseURL: baseURL)))
    }

    var body: some View {
        let shown = PronunciationModel.filter(model.list, query: query)
        PaneScaffold(
            title: DashboardPane.pronunciation.title,
            subtitle: DashboardPane.pronunciation.subtitle
        ) {
            Button {
                editing = .new
            } label: {
                Label("Add a word", systemImage: "plus")
            }
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                searchField
                if let error = model.lastError ?? tester.failure {
                    Text(error)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.negative)
                }
                DashCard { mine(shown.mine) }
                DashCard { starter(shown.starter) }
            }
        }
        .task { await model.refresh() }
        .sheet(item: $editing) { target in
            editor(for: target)
        }
    }

    // MARK: - sections

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DashboardDesign.tertiary)
            TextField("Search words and respellings", text: $query)
                .textFieldStyle(.plain)
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.title)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.card))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardDesign.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func mine(_ entries: [PronunciationEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashSectionTitle("Your words").padding(.bottom, 6)
            if !model.loaded && model.isLoading {
                caption("Loading…")
            } else if model.list.entries.isEmpty {
                caption(
                    "None yet. Add a word here, or pick one from a read with “Fix pronunciation…” in History.")
            } else if entries.isEmpty {
                caption("None of your words match.")
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(word: entry.word, say: entry.say, note: nil, key: entry.id) {
                    Toggle("", isOn: Binding(
                        get: { entry.enabled },
                        set: { on in Task { await model.edit(entry, enabled: on) } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(entry.enabled ? "On" : "Off")
                    iconButton("pencil", help: "Edit") { editing = .entry(entry) }
                    iconButton("trash", help: "Delete") { Task { await model.delete(entry) } }
                }
                if index < entries.count - 1 { DashDivider() }
            }
        }
    }

    @ViewBuilder
    private func starter(_ entries: [StarterPronunciation]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashRow(
                "Starter list",
                help: "Tech words the voices get wrong, each checked against what Kokoro actually says. "
                    + "Switch off any you don't want."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.list.starterEnabled },
                    set: { on in Task { await model.setStarter(enabled: on) } }
                ))
                .labelsHidden().toggleStyle(.switch)
            }
            DashDivider()
            if entries.isEmpty, model.loaded {
                caption("No starter words match.").padding(.top, 6)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                row(
                    word: entry.word,
                    say: entry.say,
                    note: entry.overridden ? "Your own entry for this word is used instead."
                        : entry.heard.map { "Without it: \($0)" },
                    key: "starter-" + entry.id
                ) {
                    Toggle("", isOn: Binding(
                        get: { entry.enabled },
                        set: { on in Task { await model.setStarter(entry, enabled: on) } }
                    ))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    iconButton("square.and.pencil", help: "Make your own version of this word") {
                        editing = .starter(entry)
                    }
                }
                .opacity(model.list.starterEnabled && entry.enabled && !entry.overridden ? 1 : 0.45)
                if index < entries.count - 1 { DashDivider() }
            }
        }
    }

    // MARK: - pieces

    private func row<Controls: View>(
        word: String, say: String, note: String?, key: String, @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(word).font(DashboardDesign.bodyFont).foregroundStyle(DashboardDesign.title)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(DashboardDesign.tertiary)
                    Text(say).font(DashboardDesign.bodyFont).foregroundStyle(DashboardDesign.secondary)
                }
                .lineLimit(1)
                if let note {
                    Text(note).font(DashboardDesign.captionFont).foregroundStyle(DashboardDesign.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                tester.play(say, key: key)
            } label: {
                if tester.loadingKey == key {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: "play.circle").font(.system(size: 14))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DashboardDesign.secondary)
            .help("Hear “\(say)” in your current voice")
            controls()
        }
        .padding(.vertical, 7)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DashboardDesign.tertiary)
        .help(help)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(DashboardDesign.bodyFont)
            .foregroundStyle(DashboardDesign.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func editor(for target: EditTarget) -> some View {
        switch target {
        case .new:
            PronunciationEditorSheet(title: "Add a word", tester: tester) { word, say in
                await model.add(word: word, say: say)
            }
        case .entry(let entry):
            PronunciationEditorSheet(
                title: "Edit “\(entry.word)”", word: entry.word, say: entry.say, tester: tester
            ) { word, say in
                await model.edit(entry, word: word, say: say)
            }
        case .starter(let entry):
            PronunciationEditorSheet(
                title: "Your own “\(entry.word)”", word: entry.word, say: entry.say, tester: tester
            ) { word, say in
                await model.add(word: word, say: say)
            }
        }
    }
}
