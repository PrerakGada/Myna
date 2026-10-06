// EnginePane.swift — choose the voice engine, download it, switch to it.
//
// Three blocks, in the order people need them:
//   1. The engine speaking right now, with live memory and model state.
//   2. The library: every engine Myna knows, each with its key numbers on
//      the card and the full measured profile on hover (or the ⓘ button),
//      compared against the other engines so the trade-off is visible.
//   3. Diagnostics — versions, process ids, ports — collapsed, because they
//      matter when something is wrong and are noise when nothing is.
//
// The numbers come from the Phase 0 bake-off (tools/engine-bakeoff), sent by
// the daemon with each engine. They are the same for everyone; live numbers
// for this Mac are only the ones in the "Speaking now" card.
import AppKit
import SwiftUI

struct EnginePane: View {
    let client: DaemonClient
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var menuController: MenuBarController
    @StateObject private var preview: VoicePreviewService

    @State private var catalog: EnginesResponse?
    @State private var catalogError: String?
    @State private var health: HealthResponse?
    @State private var healthError: String?
    @State private var model: ModelStatusResponse?
    @State private var checking = false
    @State private var restartOutput: String?
    @State private var busyEngine: String?
    @State private var actionError: (engine: String, message: String)?
    @State private var confirmRemove: EngineEntry?
    @State private var showDiagnostics = false

    init(
        client: DaemonClient,
        settings: SettingsViewModel,
        menuController: MenuBarController,
        player: AudioPlayer
    ) {
        self.client = client
        self.settings = settings
        self.menuController = menuController
        _preview = StateObject(wrappedValue: VoicePreviewService(client: client, sink: player))
    }

    private var engines: [EngineEntry] { catalog?.engines ?? [] }
    private var activeEngine: EngineEntry? { engines.first { $0.active } }
    private var switchingTo: EngineEntry? {
        let id = busyEngine ?? catalog?.switchingTo
        return engines.first { $0.id == id && !$0.active && $0.isInstalled }
    }
    /// Poll quickly only while something is moving.
    private var needsFastPoll: Bool {
        busyEngine != nil || catalog?.switchingTo != nil || engines.contains { $0.state == .downloading }
    }

    var body: some View {
        PaneScaffold(
            title: DashboardPane.daemon.title,
            subtitle: DashboardPane.daemon.subtitle
        ) {
            HStack(spacing: 8) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label(checking ? "Checking…" : "Recheck", systemImage: "arrow.clockwise")
                }
                .disabled(checking)
                Button {
                    Task { await restart() }
                } label: {
                    Label("Restart", systemImage: "power")
                }
                .disabled(restartOutput == "running…")
            }
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                speakingNowCard
                if let restartOutput {
                    DashCard {
                        Text(restartOutput)
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.secondary)
                            .textSelection(.enabled)
                    }
                }
                libraryHeader
                library
                diagnostics
            }
        }
        .task { await refreshAll() }
        .task(id: needsFastPoll) { await pollLoop() }
        .confirmationDialog(
            "Remove \(confirmRemove?.name ?? "")?",
            isPresented: Binding(
                get: { confirmRemove != nil },
                set: { if !$0 { confirmRemove = nil } }
            ),
            presenting: confirmRemove
        ) { engine in
            Button("Remove \(EngineFormat.size(engine.diskMb ?? Double(engine.downloadMb)))", role: .destructive) {
                Task { await remove(engine) }
            }
        } message: { _ in
            Text("Its files are deleted from this Mac. You can download it again any time.")
        }
    }

    // MARK: speaking now

    private var speakingNowCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(speakingHeadline)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DashboardDesign.title)
                        Text(speakingDetail)
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if switchingTo != nil {
                        ProgressView().controlSize(.small)
                    } else if activeEngine != nil {
                        Button {
                            preview.preview(voiceId: settings.voice)
                        } label: {
                            Label(preview.isBusy ? "Playing…" : "Play a sample", systemImage: "play.fill")
                        }
                        .disabled(preview.isBusy || health?.engineUp != true)
                    }
                }
                if let active = activeEngine {
                    HStack(spacing: 0) {
                        liveFigure("Memory now", model?.engineMemoryMb.map(EngineFormat.memory) ?? "—",
                                   help: "What the engine process holds right now, model included.")
                        liveFigure("Model", model.map { $0.modelLoaded ? "Loaded" : "Loads on first read" } ?? "—",
                                   help: "Loaded models answer at once; the first read after a restart loads it.")
                        liveFigure("Voice", voiceLabel(for: active),
                                   help: "Change it on the Voices page.")
                        liveFigure("On disk", active.diskMb.map(EngineFormat.size) ?? EngineFormat.size(Double(active.downloadMb)),
                                   help: "Space the model's files take.")
                    }
                }
            }
        }
    }

    private func liveFigure(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(DashboardDesign.body)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }

    private func voiceLabel(for engine: EngineEntry) -> String {
        engine.voices.first { $0.id == settings.voice }?.label
            ?? engine.voices.first { $0.id == engine.defaultVoice }?.label
            ?? settings.voice
    }

    private var speakingHeadline: String {
        if healthError != nil { return "Cannot reach the daemon" }
        if let switching = switchingTo { return "Switching to \(switching.name)…" }
        guard let health else { return checking ? "Checking…" : "Unknown" }
        if !health.engineUp { return "The voice engine is down" }
        if let active = activeEngine { return "Speaking with \(active.name)" }
        return "Everything is running"
    }

    private var speakingDetail: String {
        if let healthError { return healthError }
        if switchingTo != nil {
            return "Loading the model and reading a warm-up line. Larger models take up to a minute the first time."
        }
        guard let health else {
            return "Myna talks to a local service on your Mac. Nothing here leaves the machine."
        }
        if !health.engineUp {
            return "The daemon answered but the voice engine did not. Restart usually fixes it."
        }
        return activeEngine?.tagline ?? "Daemon v\(health.version) and the voice engine are both answering."
    }

    private var statusColor: Color {
        if healthError != nil { return DashboardDesign.negative }
        if switchingTo != nil { return DashboardDesign.info }
        guard let health else { return DashboardDesign.tertiary }
        if !health.ok { return DashboardDesign.negative }
        return health.engineUp ? DashboardDesign.positive : DashboardDesign.warning
    }

    // MARK: library

    private var libraryHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            DashSectionTitle("Engines")
            Spacer()
            Text("Hover an engine for its measured numbers.")
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var library: some View {
        if let catalogError, catalog == nil {
            DashCard {
                Text(catalogError)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            }
        } else if engines.isEmpty {
            DashCard {
                Text(checking ? "Loading engines…" : "This daemon doesn't offer a choice of engines yet. Update Myna.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: DashboardDesign.gridSpacing),
                          GridItem(.flexible(), spacing: DashboardDesign.gridSpacing)],
                spacing: DashboardDesign.gridSpacing
            ) {
                ForEach(engines) { engine in
                    EngineCard(
                        engine: engine,
                        all: engines,
                        isSwitching: switchingTo?.id == engine.id,
                        isBusy: busyEngine != nil || catalog?.switchingTo != nil,
                        error: actionError?.engine == engine.id ? actionError?.message : nil,
                        onDownload: { Task { await install(engine) } },
                        onUse: { Task { await activate(engine) } },
                        onRemove: { confirmRemove = engine }
                    )
                }
            }
            if let credits = creditsLine {
                Text(credits)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
            }
        }
    }

    private var creditsLine: String? {
        let credits = engines.compactMap(\.credit)
        return credits.isEmpty ? nil : credits.joined(separator: " ")
    }

    private var diagnostics: some View {
        EngineDiagnostics(
            health: health,
            model: model,
            activeRepo: activeEngine?.repo,
            settings: settings,
            menuController: menuController,
            expanded: $showDiagnostics
        )
    }

    // MARK: actions

    private func refreshAll() async {
        checking = true
        defer { checking = false }
        healthError = nil
        do {
            health = try await client.health()
        } catch {
            health = nil
            healthError = String(describing: error)
        }
        await refreshCatalog()
        model = try? await client.modelStatus()
    }

    private func refreshCatalog() async {
        do {
            catalog = try await client.engines()
            catalogError = nil
        } catch DaemonError.notFound {
            catalog = nil
            catalogError = "This daemon doesn't offer a choice of engines yet. Update Myna."
        } catch {
            catalogError = String(describing: error)
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let interval: UInt64 = needsFastPoll ? 1_000_000_000 : 10_000_000_000
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { return }
            await refreshCatalog()
            if !needsFastPoll { model = try? await client.modelStatus() }
        }
    }

    private func install(_ engine: EngineEntry) async {
        actionError = nil
        do {
            _ = try await client.installEngine(id: engine.id)
        } catch {
            actionError = (engine.id, message(for: error))
        }
        await refreshCatalog()
    }

    private func activate(_ engine: EngineEntry) async {
        actionError = nil
        busyEngine = engine.id
        defer { busyEngine = nil }
        do {
            let result = try await client.activateEngine(id: engine.id)
            // The app sends its saved voice with every read; point it at a
            // voice this engine has so the Voices page shows the right one.
            settings.voice = result.voice
            _ = try? await client.voices(forceRefresh: true)
            await menuController.refresh()
        } catch {
            actionError = (engine.id, message(for: error))
        }
        await refreshCatalog()
        model = try? await client.modelStatus()
    }

    private func remove(_ engine: EngineEntry) async {
        actionError = nil
        do {
            _ = try await client.removeEngine(id: engine.id)
        } catch {
            actionError = (engine.id, message(for: error))
        }
        await refreshCatalog()
    }

    private func message(for error: Error) -> String {
        if let engineError = error as? EngineActionError { return engineError.message }
        if case DaemonError.transport(let text) = error {
            return text.contains("timed out")
                ? "Still loading after five minutes. Check the engine log from Logs."
                : text
        }
        return String(describing: error)
    }

    private func restart() async {
        restartOutput = "running…"
        restartOutput = await DaemonService.restart()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await refreshAll()
    }
}

// MARK: - Diagnostics

/// Versions, memory, process ids and ports — collapsed by default because
/// they only matter when something is wrong.
private struct EngineDiagnostics: View {
    let health: HealthResponse?
    let model: ModelStatusResponse?
    let activeRepo: String?
    @ObservedObject var settings: SettingsViewModel
    @ObservedObject var menuController: MenuBarController
    @Binding var expanded: Bool

    var body: some View {
        DashCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    DashRow("Daemon version") { value(health?.version) }
                    DashDivider()
                    DashRow("Engine model", help: "The Hugging Face model the engine loads.") {
                        value(menuController.status?.engine.model ?? activeRepo)
                    }
                    DashDivider()
                    DashRow("Engine memory", help: "Physical footprint of the engine process, weights included.") {
                        value(model?.engineMemoryMb.map(EngineFormat.memory))
                    }
                    DashDivider()
                    DashRow("Daemon memory", help: "The daemon itself — it never holds a model.") {
                        value(model.map { EngineFormat.memory($0.daemonRssMb) })
                    }
                    DashDivider()
                    DashRow("Process ids") {
                        value(model.map { m in
                            "daemon \(m.daemonPID)" + (m.enginePID.map { " · engine \($0)" } ?? "")
                        })
                    }
                    if let status = menuController.status {
                        DashDivider()
                        DashRow("Uptime") { value(HistoryAnalytics.durationString(status.daemon.uptimeS)) }
                    }
                    DashDivider()
                    addressRows
                }
                .padding(.top, 10)
            } label: {
                Text("Diagnostics")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
            }
        }
    }

    private func value(_ text: String?) -> some View {
        Text(text ?? "—")
            .foregroundStyle(DashboardDesign.body)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var addressRows: some View {
        DashRow(
            "Daemon",
            help: settings.daemonURLError
                ?? "Must stay on localhost. Myna refuses a remote address on purpose."
        ) {
            HStack(spacing: 6) {
                TextField("", text: $settings.daemonURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { _ = settings.setDaemonURL(settings.daemonURL) }
                TextField("", value: $settings.daemonPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
            }
        }
        DashDivider()
        DashRow("Voice engine") {
            HStack(spacing: 6) {
                TextField("", text: $settings.engineURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                TextField("", value: $settings.enginePort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
            }
        }
    }
}
