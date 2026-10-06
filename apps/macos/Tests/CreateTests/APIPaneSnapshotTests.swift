// APIPaneSnapshotTests.swift — renders the API pane's cards offscreen to
// PNGs so the layout can be looked at without launching the app: at the
// Dashboard's minimum and default content widths, in the states that
// matter (ready with traffic, network access on, restarting, down).
//
// Opt-in, because it writes files and proves nothing by itself:
//   TEST_RUNNER_MYNA_SNAPSHOT_DIR=/some/dir just test-swift-only APIPaneSnapshotTests
// Every request goes to APIStubProtocol; nothing touches a real daemon or
// the app's preferences.
import AppKit
import SwiftUI
import XCTest

@testable import Myna

@MainActor
final class APIPaneSnapshotTests: XCTestCase {

    // swiftlint:disable:next force_unwrapping
    private let base = URL(string: "http://127.0.0.1:8766")!

    private var outputDir: URL {
        get throws {
            guard let dir = ProcessInfo.processInfo.environment["MYNA_SNAPSHOT_DIR"], !dir.isEmpty else {
                throw XCTSkip("set TEST_RUNNER_MYNA_SNAPSHOT_DIR to render the API pane")
            }
            return URL(fileURLWithPath: dir)
        }
    }

    private static let minWidth = DashboardDesign.minWindowWidth - DashboardDesign.sidebarWidth
    private static let defaultWidth = DashboardDesign.windowWidth - DashboardDesign.sidebarWidth

    override func setUp() {
        super.setUp()
        APIStubProtocol.reset()
    }

    override func tearDown() {
        APIStubProtocol.reset()
        super.tearDown()
    }

    func test_render_ready_with_traffic() async throws {
        let dir = try outputDir
        stubDaemon(lan: false)
        let model = try await loadedModel()
        let tryIt = APITryItModel(render: RenderClient(baseURL: base, session: APIStubProtocol.session()))
        for width in [Self.minWidth, Self.defaultWidth] {
            try await render(APIPaneCards(model: model, tryIt: tryIt), width: width, to: dir, name: "ready-\(Int(width))")
        }
    }

    func test_render_every_quick_start_tab_with_network_on() async throws {
        let dir = try outputDir
        stubDaemon(lan: true)
        let model = try await loadedModel()
        let cards = VStack(spacing: DashboardDesign.gridSpacing) {
            ForEach(APISnippets.Kind.allCases) { kind in
                APIQuickStartCard(model: model, pinnedTab: kind, showNetworkVersion: kind == .apps || kind == .curl)
            }
            APIAccessCard(model: model)
        }
        try await render(cards, width: Self.minWidth, to: dir, name: "tabs-\(Int(Self.minWidth))")
    }

    func test_render_a_finished_take_and_a_restart_that_needs_a_hand() async throws {
        let dir = try outputDir
        stubDaemon(lan: true)
        let pending = """
            {"base_url": "http://127.0.0.1:8766/v1", "lan_enabled": true, "lan_urls": ["http://Nebula.local:8766/v1"],
             "api_key": "myna-3f9c2a71d0b84e55a1b2c3d4", "requires_key_on_lan": true, "restart_pending": true}
            """
        APIStubProtocol.json("GET", "/v2/api/settings", pending)
        APIStubProtocol.on("POST", "/v1/audio/speech") { _ in
            APIStubProtocol.Reply(
                status: 200, body: Data(count: 96_000),
                headers: ["Content-Type": "audio/wav", "X-Myna-Engine": "kokoro", "X-Myna-Voice": "af_heart",
                          "X-Myna-Duration-S": "2.00"])
        }
        let session = APIStubProtocol.session()
        let model = APIPaneModel(
            render: RenderClient(baseURL: base, session: session),
            daemon: DaemonClient(baseURL: base, session: session),
            restartPollInterval: 0.01, restartMaxAttempts: 2)
        await model.refresh()
        await model.waitForRestart(desiredLAN: nil)
        XCTAssertEqual(model.status, .restartNeeded)

        let tryIt = APITryItModel(render: RenderClient(baseURL: base, session: session))
        tryIt.autoPlay = false
        tryIt.chooseFormat("wav")
        tryIt.run()
        while tryIt.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        let cards = VStack(spacing: DashboardDesign.gridSpacing) {
            APIStatusCard(model: model)
            APITryItCard(model: model, tryIt: tryIt)
            APIAccessCard(model: model)
        }
        try await render(cards, width: Self.minWidth, to: dir, name: "take-restart")
    }

    func test_render_unreachable_and_empty() async throws {
        let dir = try outputDir
        let model = APIPaneModel(
            render: RenderClient(baseURL: base, session: APIStubProtocol.session()),
            daemon: DaemonClient(baseURL: base, session: APIStubProtocol.session()))
        await model.refresh()
        await model.refreshLog()
        let tryIt = APITryItModel(render: RenderClient(baseURL: base, session: APIStubProtocol.session()))
        try await render(APIPaneCards(model: model, tryIt: tryIt), width: Self.minWidth, to: dir, name: "down")
    }

    // MARK: - fixtures

    private func stubDaemon(lan: Bool) {
        let settings = """
            {"base_url": "http://127.0.0.1:8766/v1", "lan_enabled": \(lan),
             "lan_urls": ["http://192.168.1.20:8766/v1", "http://10.0.0.7:8766/v1"],
             "api_key": "myna-3f9c2a71d0b84e55a1b2c3d4", "requires_key_on_lan": true, "restart_pending": false}
            """
        APIStubProtocol.json("GET", "/v2/api/settings", settings)
        APIStubProtocol.json("GET", "/v2/health", #"{"ok": true, "version": "0.6.0", "engine_up": true}"#)
        if let engines = try? FixtureLoader.data("engines-response.json") {
            APIStubProtocol.on("GET", "/v2/engines") { _ in APIStubProtocol.Reply(status: 200, body: engines) }
        }
        if let voices = try? FixtureLoader.data("voices-response.json") {
            APIStubProtocol.on("GET", "/v2/voices") { _ in APIStubProtocol.Reply(status: 200, body: voices) }
        }
        APIStubProtocol.json("GET", "/v2/formats", """
            {"formats": [
              {"id": "wav", "label": "WAV", "available": true, "ext": "wav", "mime": "audio/wav"},
              {"id": "m4a", "label": "M4A (AAC)", "available": true, "ext": "m4a", "mime": "audio/mp4"},
              {"id": "mp3", "label": "MP3", "available": false, "ext": "mp3", "mime": "audio/mpeg",
               "reason": "needs ffmpeg or lame"}
            ]}
            """)
        APIStubProtocol.json("GET", "/v2/api/log", """
            {"requests": [
              {"at": 1790701090.2, "method": "POST", "path": "/v1/audio/speech", "client": "192.168.1.42",
               "user_agent": "OpenAI/Python 1.40.0", "status": 200, "ms": 1830, "chars": 412,
               "format": "mp3", "voice": "af_heart", "audio_s": 24.1},
              {"at": 1790701060.0, "method": "GET", "path": "/v2/renders/r_7f3a9c21", "client": "127.0.0.1",
               "user_agent": "curl/8.7.1", "status": 200, "ms": 3, "audio_s": 1204.6},
              {"at": 1790701030.2, "method": "POST", "path": "/v1/audio/speech", "client": "127.0.0.1",
               "user_agent": "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",
               "status": 401, "ms": 1, "chars": 5000},
              {"at": 1790701000.0, "method": "POST", "path": "/v1/audio/speech", "client": "127.0.0.1",
               "user_agent": "Myna/57 CFNetwork/1568.100.1 Darwin/25.0.0", "status": 502, "ms": 12400,
               "chars": 48211}
            ]}
            """)
    }

    private func loadedModel() async throws -> APIPaneModel {
        let session = APIStubProtocol.session()
        let model = APIPaneModel(
            render: RenderClient(baseURL: base, session: session),
            daemon: DaemonClient(baseURL: base, session: session))
        await model.refresh()
        await model.refreshLog()
        return model
    }

    // MARK: - rendering

    private func render<V: View>(_ content: V, width: CGFloat, to dir: URL, name: String) async throws {
        let root = content
            .padding(.horizontal, DashboardDesign.panePadding)
            .padding(.vertical, 24)
            .frame(width: width)
            .background(DashboardDesign.surface)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI run its onAppear/onChange pass and lay out again.
        try await Task.sleep(nanoseconds: 400_000_000)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("api-pane-\(name).png"))
        window.close()
    }
}
