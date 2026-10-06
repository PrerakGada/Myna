// StudioPane.swift — Studio: turn articles, documents and books into
// audio files you keep.
//
// The pane is the library of everything rendered (newest first, with
// what's rendering at the top of that order) and the ways to start a new
// conversion: paste text, fetch a web page, or add files, from the New
// menu, the empty state's buttons, or by dropping onto the pane.
//
// Rendering is the daemon's (RENDER_API.md §2): jobs survive the window
// closing and the app quitting. The pane only polls while it's on screen.
//
// Not here, on purpose: a notification when a long render finishes. Myna
// never asks for notification permission and posts none anywhere (the
// `useNotifications` setting is stored but unused), so Studio doesn't
// start; the library shows the state whenever the pane is opened.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StudioPane: View {
    let context: DashboardContext
    @ObservedObject var launcher: DashboardLauncher
    @StateObject private var composer: StudioComposer
    private let library: StudioLibrary

    init(context: DashboardContext, launcher: DashboardLauncher) {
        self.context = context
        self.launcher = launcher
        library = StudioLibrary.shared(baseURL: context.settings.fullDaemonBaseURL ?? DaemonClient.defaultBaseURL)
        _composer = StateObject(wrappedValue: StudioComposer(
            client: context.client, settings: context.settings, history: context.history))
    }

    var body: some View {
        StudioLibraryPane(library: library, player: StudioPlayer.shared, composer: composer)
            .onAppear(perform: takePlaygroundText)
    }

    /// Text the Playground's "Send to Studio" left behind (too long for one
    /// take) goes straight to review.
    private func takePlaygroundText() {
        guard let text = PlaygroundHandoff.takeStudioText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composer.startPaste(text: text)
        composer.continueFromPaste()
    }
}

/// The pane's content, built from its three models alone so it can be
/// drawn offscreen in tests without the rest of the app.
struct StudioLibraryPane: View {
    @ObservedObject var library: StudioLibrary
    @ObservedObject var player: StudioPlayer
    @ObservedObject var composer: StudioComposer

    @State private var query = ""
    @State private var dropTargeted = false
    @State private var expandedId: String?
    @State private var confirmingDelete: RenderJob?

    init(library: StudioLibrary, player: StudioPlayer, composer: StudioComposer, expandedId: String? = nil) {
        self.library = library
        self.player = player
        self.composer = composer
        _expandedId = State(initialValue: expandedId)
    }

    private var filtered: [RenderJob] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return library.jobs }
        return library.jobs.filter { $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        PaneScaffold(
            title: DashboardPane.studio.title,
            subtitle: DashboardPane.studio.subtitle,
            scrolls: false
        ) {
            newMenu
        } content: {
            VStack(spacing: 12) {
                if let error = library.loadError {
                    notice(error, tint: DashboardDesign.warning, retry: { Task { await library.refresh() } })
                }
                if let error = library.actionError ?? player.error {
                    notice(error, tint: DashboardDesign.negative, dismiss: {
                        library.actionError = nil
                        player.error = nil
                    })
                }
                if !library.loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if library.jobs.isEmpty {
                    emptyState
                    Spacer(minLength: 0)
                } else {
                    filterBar
                    list
                }
                if player.jobId != nil {
                    StudioPlayerBar(player: player)
                }
            }
        }
        .overlay { if dropTargeted { dropHighlight } }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropTargeted, perform: handleDrop)
        .sheet(isPresented: $composer.isPresented) {
            StudioComposerSheet(
                composer: composer,
                library: library,
                onChooseFiles: chooseFiles,
                onClose: { composer.isPresented = false }
            )
        }
        .confirmationDialog(
            "Delete “\(confirmingDelete?.title ?? "")”?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { job in
            Button("Delete", role: .destructive) { delete(job) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the audio file from this Mac. Copies you saved or shared elsewhere are kept.")
        }
        .task(id: library.hasActiveJobs) { await library.pollLoop() }
        .onDisappear { player.pause() }
    }

    // MARK: - header

    private var newMenu: some View {
        Menu {
            Button("Paste Text…", action: startPaste)
            Button("From a Web Page…", action: startWeb)
            Button("Choose Files…", action: chooseFiles)
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Make a new audio file")
    }

    // MARK: - empty state

    private var emptyState: some View {
        DashCard {
            VStack(spacing: 14) {
                DashEmptyState(
                    systemImage: "tray.and.arrow.down",
                    title: "Make audio files from long text",
                    message: "Studio reads an article, a document or a whole book in your voice and saves it "
                        + "as an audio file you can play here, keep, or send to your phone."
                )
                .padding(.bottom, -28)
                HStack(spacing: 10) {
                    Button(action: startPaste) { Label("Paste Text", systemImage: "doc.on.clipboard") }
                    Button(action: startWeb) { Label("From a Web Page", systemImage: "safari") }
                    Button(action: chooseFiles) { Label("Choose Files…", systemImage: "folder") }
                }
                .controlSize(.large)
                Text("Or drop a file here: text, Markdown, RTF, Word, OpenDocument, HTML, PDF or EPUB.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
    }

    // MARK: - library

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardDesign.tertiary)
                TextField("Search titles", text: $query)
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
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardDesign.border, lineWidth: 1))

            Text(storageSummary)
                .font(DashboardDesign.captionFont.monospacedDigit())
                .foregroundStyle(DashboardDesign.tertiary)
                .lineLimit(1)
                .fixedSize()
                .help("Files live in ~/Library/Application Support/Myna/renders")
        }
    }

    private var storageSummary: String {
        let count = library.doneCount
        let files = "\(count) file\(count == 1 ? "" : "s")"
        return count == 0 ? files : files + " · " + StudioFormat.bytes(library.totalBytes)
    }

    private var list: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                if filtered.isEmpty {
                    DashEmptyState(
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "Nothing matches",
                        message: "No title contains “\(query)”."
                    )
                } else {
                    ForEach(filtered) { job in
                        row(job)
                        DashDivider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous).fill(DashboardDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(DashboardDesign.border, lineWidth: 1)
        )
    }

    private func row(_ job: RenderJob) -> some View {
        StudioJobRow(
            job: job,
            presentation: library.presentation(for: job),
            isExpanded: expandedId == job.id,
            isCurrent: player.jobId == job.id,
            isPlaying: player.jobId == job.id && player.isPlaying,
            isBusy: library.busyIds.contains(job.id),
            onToggleExpanded: { expandedId = expandedId == job.id ? nil : job.id },
            actions: StudioRowActions(
                play: { player.toggle(job) },
                playChapter: { index in player.play(job, from: job.chapters?[safe: index]?.startS ?? 0) },
                cancel: { Task { await library.cancel(job) } },
                retry: { Task { await library.retry(job) } },
                delete: { confirmingDelete = job },
                reveal: { run { try StudioFileActions.reveal(job) } },
                saveCopy: { run { try StudioFileActions.saveCopy(job) } },
                share: { view in
                    guard let view else { return }
                    run { try StudioFileActions.share(job, from: view) }
                }
            )
        )
    }

    // MARK: - notices

    private func notice(
        _ message: String,
        tint: Color,
        retry: (() -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let retry { Button("Try Again", action: retry).controlSize(.small) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(DashboardDesign.secondary)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
            .strokeBorder(DashboardDesign.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                    .fill(DashboardDesign.accent.opacity(0.06))
            )
            .overlay {
                Label("Drop to make an audio file", systemImage: "tray.and.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DashboardDesign.title)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: - actions

    private func startPaste() {
        composer.startPaste()
    }

    private func startWeb() {
        composer.startWeb()
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = DocumentImporter.contentTypes
        panel.message = "Choose one file, or several to join into one audio file in name order."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        composer.startFiles(panel.urls)
    }

    private func delete(_ job: RenderJob) {
        if player.jobId == job.id { player.close() }
        if expandedId == job.id { expandedId = nil }
        Task { await library.delete(job) }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            library.actionError = error.localizedDescription
        }
    }

    // MARK: - drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let composer = self.composer
        let library = self.library
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            StudioDrop.loadURLs(files) { urls in
                Task { @MainActor in
                    let readable = urls.filter { $0.isFileURL && DocumentImporter.format(for: $0) != nil }
                    if readable.isEmpty {
                        library.actionError = urls.first.map {
                            StudioImportError.unsupported($0.lastPathComponent).localizedDescription
                        }
                    } else {
                        composer.startFiles(readable)
                    }
                }
            }
            return true
        }
        if let link = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            StudioDrop.loadURLs([link]) { urls in
                Task { @MainActor in
                    guard let url = urls.first, ["http", "https"].contains(url.scheme?.lowercased()) else { return }
                    composer.startWeb(url: url.absoluteString)
                    await composer.fetchURL()
                }
            }
            return true
        }
        if let text = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            StudioDrop.loadText(text) { string in
                Task { @MainActor in
                    if let string { composer.startPaste(text: string) }
                }
            }
            return true
        }
        return false
    }
}

/// NSItemProvider answers on a background queue. These are nonisolated
/// so the closures they hand it carry no main-actor isolation (the macOS
/// 26 trap described in AudioPlayer.swift); callers get a `@Sendable`
/// completion and hop to the main actor themselves.
enum StudioDrop {
    nonisolated static func loadURLs(_ providers: [NSItemProvider], completion: @escaping @Sendable ([URL]) -> Void) {
        let group = DispatchGroup()
        let results = StudioDropResults(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                results.set(index, url)
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(results.values) }
    }

    nonisolated static func loadText(_ provider: NSItemProvider, completion: @escaping @Sendable (String?) -> Void) {
        _ = provider.loadObject(ofClass: String.self) { string, _ in
            completion(string)
        }
    }
}

/// Collects drop results from whichever queue they arrive on, in order.
private final class StudioDropResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        slots[index] = url
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
