// APIPaneTests.swift — the API pane's logic without its views: request
// log formatting, the restart re-poll state machine, the status line,
// the reference card's honesty (every listed myna:// route and CLI flag
// exists), and APIPaneModel end to end against a stubbed daemon.
import XCTest

@testable import Myna

// MARK: - log rows

@MainActor
final class APIPaneTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func entry(
        at: Double = 1_790_701_030.2,
        method: String = "POST",
        path: String = "/v1/audio/speech",
        client: String = "127.0.0.1",
        agent: String? = "OpenAI/Python 1.40.0",
        status: Int = 200,
        ms: Int = 1_830,
        chars: Int? = 412,
        audio: Double? = 24.1
    ) -> APIRequestLogEntry {
        let json: [String: Any?] = [
            "at": at, "method": method, "path": path, "client": client, "user_agent": agent,
            "status": status, "ms": ms, "chars": chars, "format": "mp3", "voice": "af_heart", "audio_s": audio,
        ]
        let data = try? JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(APIRequestLogEntry.self, from: data ?? Data())
    }

    func test_log_row_formats_every_column() {
        let row = APILogRow(entry(), timeZone: utc)
        XCTAssertEqual(row.time, "16:57:10")
        XCTAssertEqual(row.client, "This Mac")
        XCTAssertTrue(row.isLocal)
        XCTAssertEqual(row.agent, "OpenAI/Python 1.40.0")
        XCTAssertEqual(row.method, "POST")
        XCTAssertEqual(row.path, "/v1/audio/speech")
        XCTAssertEqual(row.status, "200")
        XCTAssertEqual(row.tone, .success)
        XCTAssertEqual(row.duration, "1.8 s")
        XCTAssertEqual(row.chars, "412")
        XCTAssertEqual(row.audio, "24.1 s")
    }

    func test_log_row_marks_other_devices_and_errors() {
        let row = APILogRow(entry(client: "192.168.1.42", status: 401, chars: nil, audio: nil), timeZone: utc)
        XCTAssertEqual(row.client, "192.168.1.42")
        XCTAssertFalse(row.isLocal)
        XCTAssertEqual(row.tone, .clientError)
        XCTAssertEqual(row.chars, "—")
        XCTAssertEqual(row.audio, "—")
        XCTAssertEqual(APILogFormat.tone(503), .serverError)
        XCTAssertTrue(APILogFormat.client("::1").isLocal)
    }

    func test_user_agents_are_shortened_to_something_readable() {
        XCTAssertEqual(APILogFormat.userAgent("curl/8.7.1"), "curl 8.7.1")
        XCTAssertEqual(APILogFormat.userAgent("OpenAI/JS 4.56.0"), "OpenAI/JS 4.56.0")
        XCTAssertEqual(APILogFormat.userAgent("Myna/57 CFNetwork/1568.100.1 Darwin/25.0.0"), "Myna 57")
        XCTAssertEqual(APILogFormat.userAgent("python-requests/2.32.3"), "python-requests 2.32.3")
        XCTAssertEqual(
            APILogFormat.userAgent(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                    + "Version/18.0 Safari/605.1.15"),
            "Safari")
        XCTAssertEqual(
            APILogFormat.userAgent("Mozilla/5.0 (X11) AppleWebKit/537.36 Chrome/129.0 Safari/537.36"), "Chrome")
        XCTAssertEqual(APILogFormat.userAgent(nil), "—")
        XCTAssertEqual(APILogFormat.userAgent("  "), "—")
        let long = APILogFormat.userAgent("SomeExtremelyLongAutomationToolName/1.0")
        XCTAssertEqual(long.count, APILogFormat.maxAgentLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func test_durations_characters_and_audio_lengths() {
        XCTAssertEqual(APILogFormat.duration(ms: 412), "412 ms")
        XCTAssertEqual(APILogFormat.duration(ms: 12_400), "12 s")
        XCTAssertEqual(APILogFormat.chars(48_211), 48_211.formatted(.number.grouping(.automatic)))
        XCTAssertEqual(APILogFormat.audio(65), "1:05")
        XCTAssertEqual(APILogFormat.audio(3_723), "1:02:03")
        XCTAssertEqual(APILogFormat.audio(0), "—")
    }

    func test_log_rows_get_unique_ids_even_for_identical_entries() {
        let rows = APILogRow.rows([entry(), entry(), entry(at: 1)], timeZone: utc)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    // MARK: - restart tracker

    func test_restart_tracker_waits_through_silence_until_the_daemon_settles() {
        var tracker = APIRestartTracker(maxAttempts: 10)
        XCTAssertFalse(tracker.observe(.noAnswer), "idle trackers ignore polls")
        tracker.begin()
        XCTAssertTrue(tracker.isWaiting)
        XCTAssertTrue(tracker.observe(.answered(settled: false)), "old process still up")
        XCTAssertTrue(tracker.observe(.noAnswer), "rebinding")
        XCTAssertTrue(tracker.observe(.noAnswer))
        XCTAssertEqual(tracker.phase, .waiting(attempts: 3))
        XCTAssertFalse(tracker.observe(.answered(settled: true)))
        XCTAssertEqual(tracker.phase, .idle)
    }

    func test_restart_tracker_gives_up_after_max_attempts() {
        var tracker = APIRestartTracker(maxAttempts: 3)
        tracker.begin()
        XCTAssertTrue(tracker.observe(.noAnswer))
        XCTAssertTrue(tracker.observe(.noAnswer))
        XCTAssertFalse(tracker.observe(.noAnswer))
        XCTAssertEqual(tracker.phase, .timedOut(answering: false))
        XCTAssertFalse(tracker.observe(.answered(settled: true)), "a timed-out tracker stays put until begin()")
        tracker.begin()
        XCTAssertTrue(tracker.isWaiting)
    }

    func test_restart_tracker_tells_a_silent_daemon_from_one_that_never_applied_the_change() {
        var tracker = APIRestartTracker(maxAttempts: 2)
        tracker.begin()
        tracker.observe(.noAnswer)
        tracker.observe(.answered(settled: false))
        XCTAssertEqual(tracker.phase, .timedOut(answering: true))
        XCTAssertEqual(
            APIServiceStatus.derive(settings: nil, engineUp: true, restart: tracker), .restartNeeded)
    }

    // MARK: - status line

    private let settings = APISettings(
        baseUrl: "http://127.0.0.1:8766/v1", lanEnabled: false, lanUrls: [], apiKey: "k",
        requiresKeyOnLan: true, restartPending: false)

    func test_status_is_derived_from_settings_health_and_restart() {
        let idle = APIRestartTracker()
        var waiting = APIRestartTracker()
        waiting.begin()
        XCTAssertEqual(APIServiceStatus.derive(settings: nil, engineUp: nil, restart: idle), .checking)
        XCTAssertEqual(APIServiceStatus.derive(settings: .success(settings), engineUp: true, restart: idle), .ready)
        XCTAssertEqual(APIServiceStatus.derive(settings: .success(settings), engineUp: nil, restart: idle), .ready)
        XCTAssertEqual(
            APIServiceStatus.derive(settings: .success(settings), engineUp: false, restart: idle), .engineDown)
        XCTAssertEqual(APIServiceStatus.derive(settings: .failure(.notFound), engineUp: true, restart: idle), .noAPI)
        XCTAssertEqual(
            APIServiceStatus.derive(settings: .failure(.transport("refused")), engineUp: nil, restart: idle),
            .unreachable(RenderAPIError.transport("refused").localizedDescription))
        XCTAssertEqual(
            APIServiceStatus.derive(settings: .failure(.transport("refused")), engineUp: nil, restart: waiting),
            .restarting, "silence during a restart is expected, not an outage")
    }

    // MARK: - reference card honesty

    func test_every_listed_url_route_is_one_the_app_handles() throws {
        for route in APIReference.urlRoutes {
            let url = try XCTUnwrap(URL(string: route.value), route.value)
            XCTAssertNotNil(URLSchemeHandler.parse(url), "\(route.value) isn't a route URLSchemeHandler accepts")
        }
        XCTAssertEqual(
            URLSchemeHandler.parse(try XCTUnwrap(URL(string: "myna://dashboard?pane=api"))),
            .openDashboard(pane: .api))
    }

    func test_every_listed_cli_form_exists_in_the_cli() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CreateTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()
        let cli = try String(contentsOf: repo.appendingPathComponent("cli/myna"), encoding: .utf8)
        for command in APIReference.cliCommands {
            let flags = command.value.split(separator: " ").filter { $0.hasPrefix("--") }
            for flag in flags {
                XCTAssertTrue(cli.contains("\(flag))"), "cli/myna has no \(flag) option")
            }
            if command.value.hasPrefix("myna doctor") {
                XCTAssertTrue(cli.contains("doctor)"), "cli/myna has no doctor subcommand")
            }
        }
        XCTAssertTrue(cli.contains("TEXT=\"$(cat)\""), "piped input is read from stdin")
    }

    func test_every_endpoint_in_the_reference_is_in_the_contract() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let contract = try String(
            contentsOf: repo.appendingPathComponent("docs/native-app/RENDER_API.md"), encoding: .utf8)
        for endpoint in APIReference.endpoints {
            XCTAssertTrue(
                contract.contains("\(endpoint.method) \(endpoint.path)"),
                "RENDER_API.md doesn't document \(endpoint.id)")
        }
    }

    func test_origin_strips_the_v1_suffix() {
        XCTAssertEqual(APIPane.origin(of: "http://127.0.0.1:8766/v1"), "http://127.0.0.1:8766")
        XCTAssertEqual(APIPane.origin(of: "http://example"), "http://example")
    }
}

// MARK: - model against a stubbed daemon

@MainActor
final class APIPaneModelTests: XCTestCase {

    // swiftlint:disable:next force_unwrapping
    private let base = URL(string: "http://127.0.0.1:8766")!

    override func setUp() {
        super.setUp()
        APIStubProtocol.reset()
    }

    override func tearDown() {
        APIStubProtocol.reset()
        super.tearDown()
    }

    private func makeModel(maxAttempts: Int = 20) -> APIPaneModel {
        let session = APIStubProtocol.session()
        return APIPaneModel(
            render: RenderClient(baseURL: base, session: session),
            daemon: DaemonClient(baseURL: base, session: session),
            restartPollInterval: 0.01,
            restartMaxAttempts: maxAttempts,
            logInterval: 0.01
        )
    }

    nonisolated private static func settingsJSON(
        lan: Bool, pending: Bool, key: String = "myna-3f9c2a71d0b84e55a1b2"
    ) -> String {
        """
        {"base_url": "http://127.0.0.1:8766/v1", "lan_enabled": \(lan),
         "lan_urls": ["http://192.168.1.20:8766/v1"], "api_key": "\(key)",
         "requires_key_on_lan": true, "restart_pending": \(pending)}
        """
    }

    private func stubHealthyDaemon() throws {
        APIStubProtocol.json("GET", "/v2/health", #"{"ok": true, "version": "0.6.0", "engine_up": true}"#)
        let engines = try FixtureLoader.data("engines-response.json")
        APIStubProtocol.on("GET", "/v2/engines") { _ in APIStubProtocol.Reply(status: 200, body: engines) }
        let voices = try FixtureLoader.data("voices-response.json")
        APIStubProtocol.on("GET", "/v2/voices") { _ in APIStubProtocol.Reply(status: 200, body: voices) }
        APIStubProtocol.json("GET", "/v2/formats", """
            {"formats": [
              {"id": "wav", "label": "WAV", "available": true, "ext": "wav", "mime": "audio/wav"},
              {"id": "mp3", "label": "MP3", "available": false, "ext": "mp3", "mime": "audio/mpeg",
               "reason": "needs ffmpeg or lame"}
            ]}
            """)
    }

    func test_refresh_loads_everything_the_pane_shows() async throws {
        try stubHealthyDaemon()
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: false, pending: false))
        let model = makeModel()
        await model.refresh()

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.baseURL, "http://127.0.0.1:8766/v1")
        XCTAssertEqual(model.engineName, "Kokoro")
        XCTAssertEqual(model.defaultVoice?.id, "af_heart")
        XCTAssertEqual(model.snippetVoice, "af_heart")
        XCTAssertEqual(model.snippetFormat, "wav", "MP3 isn't available in this stub")
        XCTAssertEqual(model.mp3Unavailable?.reason, "needs ffmpeg or lame")
        XCTAssertEqual(model.settings?.apiKey, "myna-3f9c2a71d0b84e55a1b2")
    }

    func test_an_older_daemon_without_the_api_is_reported_as_such() async throws {
        try stubHealthyDaemon()
        APIStubProtocol.json("GET", "/v2/api/settings", status: 404, #"{"detail": "Not Found"}"#)
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.status, .noAPI)
        XCTAssertNil(model.settings)
        XCTAssertEqual(model.baseURL, "http://127.0.0.1:8766/v1", "falls back to the address the app uses")
    }

    func test_a_daemon_that_isnt_listening_is_unreachable() async {
        let model = makeModel()
        await model.refresh()
        guard case .unreachable = model.status else {
            return XCTFail("expected unreachable, got \(model.status)")
        }
    }

    func test_turning_on_lan_waits_for_the_restart_then_shows_the_new_setting() async throws {
        try stubHealthyDaemon()
        // Initial state, then: old process still answering, down while it
        // rebinds, back up but not yet settled, and finally settled.
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: false, pending: false))
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: true, pending: true))
        APIStubProtocol.refuse("GET", "/v2/api/settings")
        APIStubProtocol.refuse("GET", "/v2/api/settings")
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: true, pending: true))
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: true, pending: false))
        APIStubProtocol.on("POST", "/v2/api/settings") { request in
            let body = String(bytes: APIStubProtocol.body(of: request), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"lan_enabled\":true"), body)
            return APIStubProtocol.Reply(status: 200, body: Data(Self.settingsJSON(lan: true, pending: true).utf8))
        }

        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.settings?.lanEnabled, false)

        await model.setLANEnabled(true)

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.isRestarting)
        XCTAssertEqual(model.settings?.lanEnabled, true)
        XCTAssertEqual(model.settings?.restartPending, false)
        XCTAssertNil(model.accessError)
        let polls = APIStubProtocol.requests.filter { $0 == "GET /v2/api/settings" }.count
        XCTAssertGreaterThanOrEqual(polls, 6, "re-polled through the restart")
    }

    func test_a_restart_that_never_comes_back_is_reported() async throws {
        try stubHealthyDaemon()
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: false, pending: false))
        APIStubProtocol.refuse("GET", "/v2/api/settings")
        // The daemon drops the connection before replying to the POST.
        APIStubProtocol.refuse("POST", "/v2/api/settings")

        let model = makeModel(maxAttempts: 5)
        await model.refresh()
        await model.setLANEnabled(true)

        XCTAssertEqual(model.status, .restartFailed)
        XCTAssertFalse(model.isRestarting)
    }

    func test_a_daemon_that_cant_rebind_itself_says_a_restart_is_needed() async throws {
        try stubHealthyDaemon()
        // uvicorn --factory: answers throughout, restart_pending never clears.
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: false, pending: false))
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: true, pending: true))
        APIStubProtocol.json("POST", "/v2/api/settings", Self.settingsJSON(lan: true, pending: true))

        let model = makeModel(maxAttempts: 5)
        await model.refresh()
        await model.setLANEnabled(true)

        XCTAssertEqual(model.status, .restartNeeded)
        XCTAssertEqual(model.settings?.lanEnabled, true)
        // Opening the pane again must not start another 20-second wait.
        await model.refreshStatus()
        XCTAssertEqual(model.status, .restartNeeded)
        XCTAssertFalse(model.isRestarting)
    }

    func test_turning_lan_back_off_clears_a_restart_needed_state() async throws {
        try stubHealthyDaemon()
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: true, pending: true))
        APIStubProtocol.json("POST", "/v2/api/settings", Self.settingsJSON(lan: false, pending: false))
        let model = makeModel(maxAttempts: 3)
        await model.refresh()
        await model.waitForRestart(desiredLAN: nil)
        XCTAssertEqual(model.status, .restartNeeded)

        await model.setLANEnabled(false)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.settings?.lanEnabled, false)
    }

    func test_regenerating_the_key_shows_the_new_one() async throws {
        try stubHealthyDaemon()
        APIStubProtocol.json("GET", "/v2/api/settings", Self.settingsJSON(lan: true, pending: false))
        APIStubProtocol.on("POST", "/v2/api/settings") { request in
            let body = String(bytes: APIStubProtocol.body(of: request), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"regenerate_key\":true"), body)
            let fresh = Self.settingsJSON(lan: true, pending: false, key: "myna-new0000000000000000")
            return APIStubProtocol.Reply(status: 200, body: Data(fresh.utf8))
        }
        let model = makeModel()
        await model.refresh()
        await model.regenerateKey()
        XCTAssertEqual(model.settings?.apiKey, "myna-new0000000000000000")
        XCTAssertEqual(model.status, .ready)
    }

    func test_log_refresh_turns_entries_into_rows() async throws {
        APIStubProtocol.json("GET", "/v2/api/log", """
            {"requests": [{"at": 1790701030.2, "method": "POST", "path": "/v1/audio/speech",
              "client": "127.0.0.1", "user_agent": "curl/8.7.1", "status": 200, "ms": 412,
              "chars": 16, "format": "wav", "voice": "af_heart", "audio_s": 1.4}]}
            """)
        let model = makeModel()
        XCTAssertFalse(model.logLoaded)
        await model.refreshLog()
        XCTAssertTrue(model.logLoaded)
        XCTAssertEqual(model.logRows.map(\.agent), ["curl 8.7.1"])
        XCTAssertNil(model.logError)
    }

    func test_poll_loop_skips_ticks_while_the_window_is_hidden() async throws {
        APIStubProtocol.json("GET", "/v2/api/log", #"{"requests": []}"#)
        let session = APIStubProtocol.session()
        let hidden = APIPaneModel(
            render: RenderClient(baseURL: base, session: session),
            daemon: DaemonClient(baseURL: base, session: session),
            logInterval: 0.01,
            isOnScreen: { false }
        )
        let loop = Task { await hidden.pollLoop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        loop.cancel()
        await loop.value
        XCTAssertFalse(APIStubProtocol.requests.contains("GET /v2/api/log"))
    }
}
