// APIPaneLiveTests.swift — the API pane against a real daemon, for a
// developer who has one running from their worktree:
//
//   cd daemon && uv run --with-editable . uvicorn --factory myna.app:create_app --port 8792
//   TEST_RUNNER_MYNA_LIVE_API_PORT=8792 just test-swift-only APIPaneLiveTests
//
// Skipped otherwise (CI has no daemon). Never point it at the user's
// daemon on 8766: the LAN test flips network access. Speech goes to
// whatever engine that daemon proxies to, so it makes a few short clips.
import AVFoundation
import XCTest

@testable import Myna

@MainActor
final class APIPaneLiveTests: XCTestCase {

    private var port: Int {
        get throws {
            guard let raw = ProcessInfo.processInfo.environment["MYNA_LIVE_API_PORT"], let port = Int(raw) else {
                throw XCTSkip("set TEST_RUNNER_MYNA_LIVE_API_PORT to a daemon you own")
            }
            if port == 8766 { throw XCTSkip("refusing to flip LAN access on the user's daemon (8766)") }
            return port
        }
    }

    private func clients() throws -> (RenderClient, DaemonClient) {
        // Read the port first: an XCTSkip thrown inside XCTUnwrap's
        // autoclosure would be reported as a failure, not a skip.
        let port = try port
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        return (RenderClient(baseURL: base), DaemonClient(baseURL: base))
    }

    func test_refresh_reads_the_real_daemon() async throws {
        let (render, daemon) = try clients()
        let model = APIPaneModel(render: render, daemon: daemon)
        await model.refresh()
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.baseURL, "http://127.0.0.1:\(try port)/v1")
        XCTAssertNotNil(model.engineName)
        XCTAssertFalse(model.voices.isEmpty)
        XCTAssertFalse(model.formats.isEmpty)
        XCTAssertTrue(model.settings?.apiKey?.hasPrefix("myna-") == true)
    }

    func test_try_it_request_plays_and_shows_up_in_the_log() async throws {
        let (render, daemon) = try clients()
        let model = APIPaneModel(render: render, daemon: daemon)
        await model.refresh()

        let tryIt = APITryItModel(render: render)
        tryIt.adoptDefaultFormat(model.snippetFormat, available: model.formats)
        tryIt.text = "Live test."
        tryIt.run()
        let deadline = Date().addingTimeInterval(120)
        while tryIt.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .done(let take) = tryIt.phase else {
            return XCTFail("expected a take, got \(tryIt.phase)")
        }
        tryIt.stop()
        XCTAssertGreaterThan(take.bytes, 1_000)
        XCTAssertTrue(take.playable)
        XCTAssertNotNil(take.voice)
        XCTAssertGreaterThan(take.durationS ?? 0, 0.1)

        await model.refreshLog()
        let row = try XCTUnwrap(model.logRows.first)
        XCTAssertEqual(row.path, "/v1/audio/speech")
        XCTAssertEqual(row.status, "200")
        XCTAssertEqual(row.chars, "10")
        XCTAssertEqual(row.client, "This Mac")
    }

    func test_generated_curl_snippet_runs_and_returns_audio() async throws {
        let (render, daemon) = try clients()
        let model = APIPaneModel(render: render, daemon: daemon)
        await model.refresh()
        var ctx = APISnippets.Context(
            baseURL: model.baseURL, voice: model.snippetVoice, format: model.snippetFormat, apiKey: nil)
        ctx.input = "Snippet test."

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myna-curl-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", APISnippets.curl(ctx)]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "curl --fail exited non-zero")

        let file = dir.appendingPathComponent("speech.\(ctx.fileExtension)")
        let audio = try Data(contentsOf: file)
        XCTAssertGreaterThan(audio.count, 1_000)
        let player = try AVAudioPlayer(data: audio)
        XCTAssertGreaterThan(player.duration, 0.1, "the file isn't audio AVFoundation can read")
    }

    /// Writes every code snippet, filled in from the live daemon, to
    /// MYNA_SNIPPET_DIR so they can be run by hand with their real
    /// toolchains (the openai packages aren't something a test installs).
    func test_dump_snippets_for_manual_runs() async throws {
        guard let raw = ProcessInfo.processInfo.environment["MYNA_SNIPPET_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_MYNA_SNIPPET_DIR to dump the snippets")
        }
        let (render, daemon) = try clients()
        let model = APIPaneModel(render: render, daemon: daemon)
        await model.refresh()
        let ctx = APISnippets.Context(
            baseURL: model.baseURL, voice: model.snippetVoice, format: model.snippetFormat, apiKey: nil)
        let dir = URL(fileURLWithPath: raw)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files: [(String, APISnippets.Kind)] = [
            ("curl.sh", .curl), ("python.py", .python), ("node.mjs", .node), ("fetch.mjs", .fetch), ("shell.sh", .shell),
        ]
        for (name, kind) in files {
            try APISnippets.snippet(kind, ctx).write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    func test_lan_toggle_round_trip_on_a_daemon_that_cant_rebind_itself() async throws {
        // uvicorn --factory holds the change in memory with restart_pending
        // true (RENDER_API.md § 4), so the pane must end at "restart needed",
        // and turning it back off must settle cleanly.
        if ProcessInfo.processInfo.environment["MYNA_LIVE_REBIND"] == "1" {
            throw XCTSkip("this daemon can rebind itself; the rebind test covers it")
        }
        let (render, daemon) = try clients()
        let model = APIPaneModel(
            render: render, daemon: daemon, restartPollInterval: 0.1, restartMaxAttempts: 10)
        await model.refresh()
        XCTAssertEqual(model.settings?.lanEnabled, false, "start with LAN off on the test daemon")

        await model.setLANEnabled(true)
        XCTAssertEqual(model.settings?.lanEnabled, true)
        XCTAssertEqual(model.status, .restartNeeded)

        await model.setLANEnabled(false)
        XCTAssertEqual(model.settings?.lanEnabled, false)
        XCTAssertEqual(model.settings?.restartPending, false)
        XCTAssertEqual(model.status, .ready)
    }

    /// Needs a daemon started through `python -m myna` (the entry point
    /// that can re-exec itself), with its own config: set
    /// TEST_RUNNER_MYNA_LIVE_REBIND=1 as well. Checks the pane's restart
    /// flow against a real rebind, and the Access card's promise: another
    /// device needs the key, and even with it reaches only /v1.
    func test_lan_rebind_round_trip_on_a_daemon_that_rebinds_itself() async throws {
        guard ProcessInfo.processInfo.environment["MYNA_LIVE_REBIND"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_MYNA_LIVE_REBIND=1 with a python -m myna daemon")
        }
        let (render, daemon) = try clients()
        let model = APIPaneModel(render: render, daemon: daemon)
        await model.refresh()
        XCTAssertEqual(model.settings?.lanEnabled, false)

        let clock = ContinuousClock()
        let started = clock.now
        await model.setLANEnabled(true)
        let tookOn = clock.now - started
        XCTAssertEqual(model.status, .ready, "didn't settle after rebinding")
        XCTAssertEqual(model.settings?.lanEnabled, true)
        XCTAssertEqual(model.settings?.restartPending, false)
        print("LAN on settled in \(tookOn)")

        let key = try XCTUnwrap(model.settings?.apiKey)
        let lan = try await reachableLANBase(model.settings?.lanUrls ?? [])
        let origin = lan.deletingLastPathComponent()
        let noKey = try await status(lan.appendingPathComponent("models"), key: nil)
        let withKey = try await status(lan.appendingPathComponent("models"), key: key)
        let settingsFromLAN = try await status(origin.appendingPathComponent("v2/api/settings"), key: key)
        let rendersFromLAN = try await status(origin.appendingPathComponent("v2/renders"), key: key)
        XCTAssertEqual(noKey, 401)
        XCTAssertEqual(withKey, 200)
        XCTAssertEqual(settingsFromLAN, 403)
        XCTAssertEqual(rendersFromLAN, 403)

        await model.setLANEnabled(false)
        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.settings?.lanEnabled, false)
        let refused = try? await status(lan.appendingPathComponent("models"), key: key)
        XCTAssertNil(refused, "still reachable from the network after turning LAN off")
    }

    private func reachableLANBase(_ urls: [String]) async throws -> URL {
        for raw in urls {
            guard let url = URL(string: raw) else { continue }
            if (try? await status(url.appendingPathComponent("models"), key: nil)) != nil { return url }
        }
        throw XCTSkip("none of \(urls) answered from this Mac")
    }

    private func status(_ url: URL, key: String?) async throws -> Int {
        var request = URLRequest(url: url, timeoutInterval: 3)
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func test_regenerate_key_changes_it() async throws {
        let (render, daemon) = try clients()
        let model = APIPaneModel(render: render, daemon: daemon)
        await model.refresh()
        let before = try XCTUnwrap(model.settings?.apiKey)
        await model.regenerateKey()
        let after = try XCTUnwrap(model.settings?.apiKey)
        XCTAssertNotEqual(before, after)
        XCTAssertNil(model.accessError)
    }
}
