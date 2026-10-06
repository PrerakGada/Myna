// HistoryPane.swift — every read, searchable, with a detail inspector.
//
// Replaces the five-row "Recent" accordion in the popover. Rows are
// filtered client-side: the store is capped at 5,000 records and the
// predicate is a couple of string comparisons, so a live filter over the
// whole set is cheaper than any indexing scheme would be.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HistoryPane: View {
    @ObservedObject var history: HistoryStore
    let menuController: MenuBarController
    /// For "As heard": the daemon re-runs a read's text cleanup.
    let client: DaemonClient
    /// For "Fix pronunciation…": the daemon's pronunciation list.
    let daemonURL: URL

    @State private var query: String = ""
    @State private var sourceFilter: ReadSource?
    @State private var outcomeFilter: ReadOutcome?
    @State private var selectedId: String?
    @State private var confirmingClear = false

    private var filtered: [ReadEvent] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return history.events.filter { event in
            if let sourceFilter, event.source != sourceFilter { return false }
            if let outcomeFilter, event.outcome != outcomeFilter { return false }
            guard !needle.isEmpty else { return true }
            if event.title.lowercased().contains(needle) { return true }
            if event.voice.lowercased().contains(needle) { return true }
            if let app = event.appName?.lowercased(), app.contains(needle) { return true }
            if let url = event.url?.lowercased(), url.contains(needle) { return true }
            if let text = event.text?.lowercased(), text.contains(needle) { return true }
            return false
        }
    }

    private var selected: ReadEvent? {
        guard let selectedId else { return nil }
        return history.events.first { $0.id == selectedId }
    }

    var body: some View {
        PaneScaffold(
            title: DashboardPane.history.title,
            subtitle: DashboardPane.history.subtitle,
            scrolls: false
        ) {
            HStack(spacing: 8) {
                exportMenu
                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(history.events.isEmpty)
                .confirmationDialog(
                    "Delete all \(history.events.count) records?",
                    isPresented: $confirmingClear,
                    titleVisibility: .visible
                ) {
                    Button("Delete everything", role: .destructive) {
                        history.clear()
                        selectedId = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes Myna's reading history from this Mac. It cannot be undone.")
                }
            }
        } content: {
            VStack(spacing: 12) {
                filterBar
                if history.events.isEmpty {
                    DashCard {
                        DashEmptyState(
                            systemImage: "clock.arrow.circlepath",
                            title: "No history yet",
                            message: "Everything Myna reads is recorded here — the text, the voice, "
                                + "how long you listened, and whether it finished."
                        )
                    }
                    Spacer()
                } else {
                    HStack(alignment: .top, spacing: DashboardDesign.gridSpacing) {
                        list
                        if let selected {
                            HistoryDetail(
                                event: selected,
                                client: client,
                                daemonURL: daemonURL,
                                onReplay: { replay(selected) },
                                onCopy: { copy(selected) },
                                onOpenURL: { openURL(selected) },
                                onDelete: {
                                    history.delete(ids: [selected.id])
                                    selectedId = nil
                                }
                            )
                            .frame(width: 320)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - filters

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardDesign.tertiary)
                TextField("Search titles, text, voices and apps", text: $query)
                    .textFieldStyle(.plain)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.title)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DashboardDesign.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DashboardDesign.border, lineWidth: 1)
            )

            Picker("", selection: $sourceFilter) {
                Text("All sources").tag(ReadSource?.none)
                ForEach(ReadSource.allCases, id: \.self) { source in
                    Text(source.label).tag(ReadSource?.some(source))
                }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("", selection: $outcomeFilter) {
                Text("Any outcome").tag(ReadOutcome?.none)
                ForEach(ReadOutcome.allCases, id: \.self) { outcome in
                    Text(outcome.label).tag(ReadOutcome?.some(outcome))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Spacer(minLength: 0)

            Text("\(filtered.count) of \(history.events.count)")
                .font(DashboardDesign.captionFont.monospacedDigit())
                .foregroundStyle(DashboardDesign.tertiary)
        }
    }

    // MARK: - list

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    DashEmptyState(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "Nothing matches",
                        message: "No read matches those filters. Try clearing the search."
                    )
                } else {
                    ForEach(filtered) { event in
                        HistoryRow(
                            event: event,
                            isSelected: event.id == selectedId,
                            onSelect: { selectedId = event.id },
                            onReplay: { replay(event) }
                        )
                        DashDivider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .fill(DashboardDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(DashboardDesign.border, lineWidth: 1)
        )
    }

    // MARK: - export

    private var exportMenu: some View {
        Menu {
            Button("Export as JSON…") { export(.json) }
            Button("Export as CSV…") { export(.commaSeparatedText) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(history.events.isEmpty)
    }

    private func export(_ type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue =
            "myna-history-\(stamp).\(type == .json ? "json" : "csv")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if type == .json {
            try? history.exportJSON()?.write(to: url, options: .atomic)
        } else {
            try? Data(history.exportCSV().utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: - row actions

    private func replay(_ event: ReadEvent) {
        menuController.replay(event: event)
    }

    private func copy(_ event: ReadEvent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(event.text ?? event.url ?? event.title, forType: .string)
    }

    private func openURL(_ event: ReadEvent) {
        guard let raw = event.url, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - row

private struct HistoryRow: View {
    let event: ReadEvent
    let isSelected: Bool
    let onSelect: () -> Void
    let onReplay: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: event.source.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(DashboardDesign.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.truncatedTitle(maxLength: 90))
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.title)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(event.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(event.voice)
                    if event.words > 0 {
                        Text("·")
                        Text("\(HistoryAnalytics.compactCount(event.words)) words")
                    }
                    if let app = event.appName {
                        Text("·")
                        Text(app).lineLimit(1)
                    }
                }
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
            }

            Spacer(minLength: 8)

            if event.listenedSeconds > 0 {
                Text(HistoryAnalytics.durationString(event.listenedSeconds))
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.secondary)
            }
            outcomeBadge

            Button(action: onReplay) {
                Image(systemName: "play.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        isHovering ? DashboardDesign.accent : DashboardDesign.tertiary)
            }
            .buttonStyle(.plain)
            .help("Read this again")
            .accessibilityLabel("Read again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(rowFill)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected { return Color.white.opacity(0.08) }
        if isHovering { return Color.white.opacity(0.04) }
        return .clear
    }

    @ViewBuilder
    private var outcomeBadge: some View {
        switch event.outcome {
        case .reading:
            DashBadge("Reading", tint: DashboardDesign.positive)
        case .completed:
            EmptyView()
        case .stopped:
            DashBadge("Stopped", tint: DashboardDesign.secondary)
        case .failed:
            DashBadge("Failed", tint: DashboardDesign.negative)
        }
    }
}

// MARK: - detail

private struct HistoryDetail: View {
    let event: ReadEvent
    let client: DaemonClient
    let daemonURL: URL
    let onReplay: () -> Void
    let onCopy: () -> Void
    let onOpenURL: () -> Void
    let onDelete: () -> Void

    @State private var fixingPronunciation = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DashboardDesign.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(event.startedAt.formatted(date: .complete, time: .standard))
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                }

                HStack(spacing: 6) {
                    Button(action: onReplay) {
                        Label("Read again", systemImage: "play.fill")
                    }
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy the text")
                    if event.url != nil {
                        Button(action: onOpenURL) {
                            Image(systemName: "safari")
                        }
                        .help("Open the article")
                    }
                    if let text = event.text, !text.isEmpty {
                        Button {
                            fixingPronunciation = true
                        } label: {
                            Image(systemName: "character.bubble")
                        }
                        .help("Fix pronunciation… — pick a word from this read and say how it should sound")
                        .sheet(isPresented: $fixingPronunciation) {
                            PronunciationFixSheet(baseURL: daemonURL, text: text)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .help("Delete this record")
                }

                DashDivider()

                VStack(spacing: 7) {
                    DetailRow("Source", event.source.label)
                    DetailRow("Mode", event.mode.capitalized)
                    DetailRow("Voice", event.voice)
                    DetailRow("Speed", String(format: "%.2g×", event.speed))
                    DetailRow("Outcome", event.outcome.label)
                    if event.words > 0 {
                        DetailRow("Words", HistoryAnalytics.compactCount(event.words))
                        DetailRow("Characters", HistoryAnalytics.compactCount(event.characters))
                    }
                    if event.audioSeconds > 0 {
                        DetailRow(
                            "Listened",
                            "\(HistoryAnalytics.durationString(event.listenedSeconds))"
                                + " of \(HistoryAnalytics.durationString(event.audioSeconds))")
                    }
                    if let ms = event.firstAudioMs {
                        DetailRow("First word after", "\(ms) ms")
                    }
                    if let app = event.appName ?? event.appBundleId {
                        DetailRow("From app", app)
                    }
                    if let lang = event.detectedLang {
                        DetailRow("Detected language", lang.uppercased())
                    }
                    if let url = event.url {
                        DetailRow("URL", url)
                    }
                }

                if let error = event.errorMessage {
                    DashDivider()
                    VStack(alignment: .leading, spacing: 4) {
                        DashSectionTitle("Error")
                        Text(error)
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.negative)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let text = event.text, !text.isEmpty {
                    DashDivider()
                    HistoryReadText(event: event, text: text, client: client)
                        .id(event.id)
                }
            }
            .padding(DashboardDesign.cardPadding)
        }
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .fill(DashboardDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(DashboardDesign.border, lineWidth: 1)
        )
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
