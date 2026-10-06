// APIPaneModel.swift — everything the API pane shows that comes from the
// daemon: access settings, the active engine and its voices, the formats
// this Mac can encode, and the request log.
//
// Reads go through RenderClient (the /v1 + /v2/api contract,
// RENDER_API.md) and DaemonClient (health, engines, voices). The model
// owns the one fiddly flow on the pane: flipping LAN access makes the
// daemon restart itself to rebind, so for a few seconds nothing answers.
// APIRestartTracker decides when to stop waiting; this class just polls.
//
// The request log is polled every two seconds, and only while the
// Dashboard window is actually on screen — the pane's `.task` stops the
// loop when the pane goes away, and `isOnScreen` skips ticks while the
// window is minimised or covered.
import Foundation

@MainActor
final class APIPaneModel: ObservableObject {

    @Published private(set) var settings: APISettings?
    @Published private(set) var status: APIServiceStatus = .checking
    @Published private(set) var engineName: String?
    @Published private(set) var voices: [Voice] = []
    @Published private(set) var formats: [AudioFormatInfo] = []
    @Published private(set) var logRows: [APILogRow] = []
    /// False until the first log fetch returns, so the empty state doesn't
    /// flash before the data arrives.
    @Published private(set) var logLoaded = false
    @Published private(set) var logError: String?
    @Published private(set) var refreshing = false
    /// A LAN or key change is in flight.
    @Published private(set) var accessBusy = false
    @Published var accessError: String?

    let render: RenderClient
    let daemon: DaemonClient

    static let logLimit = 50

    private var settingsResult: Result<APISettings, RenderAPIError>?
    private var engineUp: Bool?
    private var engineId: String?
    private(set) var restart = APIRestartTracker()
    private let restartPollInterval: TimeInterval
    private let logInterval: TimeInterval
    private let isOnScreen: @MainActor () -> Bool

    init(
        render: RenderClient,
        daemon: DaemonClient,
        restartPollInterval: TimeInterval = APIRestartTracker.defaultPollInterval,
        restartMaxAttempts: Int = APIRestartTracker.defaultMaxAttempts,
        logInterval: TimeInterval = 2,
        isOnScreen: @escaping @MainActor () -> Bool = { true }
    ) {
        self.render = render
        self.daemon = daemon
        self.restartPollInterval = restartPollInterval
        self.logInterval = logInterval
        self.isOnScreen = isOnScreen
        restart = APIRestartTracker(maxAttempts: restartMaxAttempts)
    }

    // MARK: - derived

    /// What an OpenAI client's `base_url` should be. The daemon says; until
    /// it has, the address the app itself talks to.
    var baseURL: String {
        settings?.baseUrl ?? render.openAIBaseURL.absoluteString
    }

    /// The voice the API uses when a request names none.
    var defaultVoice: Voice? {
        voices.first(where: \.isDefault) ?? voices.first
    }

    var snippetVoice: String { APISnippets.sampleVoice(voices) }
    var snippetFormat: String { APISnippets.preferredFormat(formats) }

    /// MP3 is what OpenAI clients get when they don't name a format, so
    /// when this Mac can't make it the pane says so up front.
    var mp3Unavailable: AudioFormatInfo? {
        formats.first { $0.id == "mp3" && !$0.available }
    }

    var isRestarting: Bool { restart.isWaiting }

    // MARK: - loading

    /// Full refresh: settings, health, engine, voices, formats.
    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        async let settingsFetch = fetchSettings()
        async let healthFetch = try? daemon.health()
        async let enginesFetch = try? daemon.engines()
        async let voicesFetch = try? daemon.voices(forceRefresh: true)
        async let formatsFetch = try? render.formats()

        let fetched = await settingsFetch
        let health = await healthFetch
        let engines = await enginesFetch
        let fetchedVoices = await voicesFetch
        let fetchedFormats = await formatsFetch

        applySettings(fetched)
        engineUp = health?.engineUp
        applyEngines(engines)
        if let fetchedVoices { voices = fetchedVoices }
        if let fetchedFormats { formats = fetchedFormats }
        updateStatus()
        startRestartWaitIfPending()
    }

    /// The cheap periodic check: settings, health and which engine is
    /// active. Voices are refetched only when the engine changed.
    func refreshStatus() async {
        guard !restart.isWaiting else { return }
        async let settingsFetch = fetchSettings()
        async let healthFetch = try? daemon.health()
        async let enginesFetch = try? daemon.engines()
        let fetched = await settingsFetch
        let health = await healthFetch
        let engines = await enginesFetch

        let previousEngine = engineId
        applySettings(fetched)
        engineUp = health?.engineUp
        applyEngines(engines)
        if engineId != previousEngine || (voices.isEmpty && health?.engineUp == true),
            let fresh = try? await daemon.voices(forceRefresh: true) {
            voices = fresh
        }
        updateStatus()
        startRestartWaitIfPending()
    }

    func refreshLog() async {
        guard !restart.isWaiting else { return }
        do {
            let entries = try await render.apiLog(limit: Self.logLimit)
            logRows = APILogRow.rows(entries)
            logError = nil
        } catch RenderAPIError.notFound {
            logError = "This voice service doesn't keep a request log."
        } catch RenderAPIError.transport {
            logError = "Nothing to show while Myna's voice service isn't answering."
        } catch {
            logError = error.localizedDescription
        }
        logLoaded = true
    }

    /// Log every `logInterval`, status every fifth tick. Runs until the
    /// pane's `.task` is cancelled.
    func pollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            if isOnScreen() {
                await refreshLog()
                tick += 1
                if tick % 5 == 0 { await refreshStatus() }
            }
            try? await Task.sleep(nanoseconds: UInt64(logInterval * 1_000_000_000))
        }
    }

    // MARK: - access

    func setLANEnabled(_ enabled: Bool) async {
        guard !accessBusy, !restart.isWaiting, settings?.lanEnabled != enabled else { return }
        accessBusy = true
        accessError = nil
        defer { accessBusy = false }
        do {
            let updated = try await render.updateAPISettings(APISettingsUpdate(lanEnabled: enabled))
            applySettings(.success(updated))
            updateStatus()
            if updated.restartPending || updated.lanEnabled != enabled {
                await waitForRestart(desiredLAN: enabled)
            }
        } catch RenderAPIError.transport {
            // The daemon can go down to rebind before its reply is sent.
            // The change was made; wait for it like any other restart.
            await waitForRestart(desiredLAN: enabled)
        } catch {
            accessError = "Couldn't change network access: \(error.localizedDescription)"
        }
    }

    func regenerateKey() async {
        guard !accessBusy, !restart.isWaiting else { return }
        accessBusy = true
        accessError = nil
        defer { accessBusy = false }
        do {
            let updated = try await render.updateAPISettings(APISettingsUpdate(regenerateKey: true))
            applySettings(.success(updated))
            updateStatus()
        } catch {
            accessError = "Couldn't make a new key: \(error.localizedDescription)"
        }
    }

    // MARK: - restart

    /// Poll until the daemon answers with no pending restart (and, when
    /// the user just flipped LAN, with the setting they asked for).
    func waitForRestart(desiredLAN: Bool?) async {
        restart.begin()
        updateStatus()
        while restart.isWaiting {
            try? await Task.sleep(nanoseconds: UInt64(restartPollInterval * 1_000_000_000))
            if Task.isCancelled {
                restart.reset()
                break
            }
            let fetched = await fetchSettings()
            switch fetched {
            case .success(let fresh):
                applySettings(fetched)
                let settled = !fresh.restartPending && (desiredLAN == nil || fresh.lanEnabled == desiredLAN)
                restart.observe(.answered(settled: settled))
            case .failure:
                restart.observe(.noAnswer)
            }
            updateStatus()
        }
        if restart.phase == .idle {
            await refresh()
        }
    }

    /// A daemon that was already mid-restart when the pane opened.
    private func startRestartWaitIfPending() {
        guard settings?.restartPending == true, !restart.isWaiting, !restart.hasTimedOut else { return }
        Task { [weak self] in await self?.waitForRestart(desiredLAN: nil) }
    }

    // MARK: - helpers

    private func fetchSettings() async -> Result<APISettings, RenderAPIError> {
        do {
            return .success(try await render.apiSettings())
        } catch let error as RenderAPIError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    private func applySettings(_ result: Result<APISettings, RenderAPIError>) {
        settingsResult = result
        switch result {
        case .success(let fresh):
            settings = fresh
            // Nothing pending any more (the user flipped it back, or
            // restarted the service by hand): a past timeout no longer applies.
            if !fresh.restartPending, restart.hasTimedOut { restart.reset() }
        case .failure(.notFound):
            settings = nil
        case .failure:
            // Keep the last good settings on screen through a blip; the
            // status line says the service isn't answering.
            break
        }
    }

    private func applyEngines(_ response: EnginesResponse?) {
        guard let response else { return }
        engineId = response.active
        engineName = response.engines.first { $0.id == response.active }?.name ?? response.active
    }

    private func updateStatus() {
        status = APIServiceStatus.derive(settings: settingsResult, engineUp: engineUp, restart: restart)
    }
}
