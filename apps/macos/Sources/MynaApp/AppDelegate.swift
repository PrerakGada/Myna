// AppDelegate.swift — owns the long-lived singletons and ferries
// open-URL events into the URLSchemeHandler.
//
// Construction order:
//   1. SettingsStore + SettingsViewModel (defaults loaded)
//   2. DaemonClient (talking to the URL the user configured)
//   3. AudioPlayer (the on-process playback graph)
//   4. SelectionService + ChromeService (input)
//   5. AppDispatcher (the URLScheme + hotkey target)
//   6. URLSchemeHandler (wraps dispatcher)
//   7. HotkeyManager (wires the five global shortcuts to dispatcher)
//   8. UpdateController (Sparkle)
//   9. MenuBarController (begins /v2/status polling)
import AppKit
import Combine
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Lazy-initialised singletons. We can't construct an AudioPlayer or
    // start a daemon poll loop in `init()` because the test host loads
    // the app first and that would (a) grab the global audio session
    // before any test creates its own AudioPlayer and (b) start an
    // endless poll task that adds noise and slows tests. They're
    // wired up in `applicationDidFinishLaunching` instead, skipping
    // the wire-up entirely under XCTest.
    private(set) var settings: SettingsViewModel!
    private(set) var client: DaemonClient!
    private(set) var player: AudioPlayer!
    private(set) var selection: SelectionService!
    private(set) var chrome: ChromeService!
    private(set) var dispatcher: AppDispatcher!
    private(set) var urlHandler: URLSchemeHandler!
    private(set) var hotkeys: HotkeyManager!
    private(set) var updates: UpdateController!
    private(set) var menuController: MenuBarController!
    private var didBootstrap = false
    private let log = Log(.app)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // belt-and-braces with LSUIElement.

        // Don't initialise live audio/hotkey/poll machinery when the
        // binary is hosting an XCTest bundle — those side effects would
        // fight with the user's running v1 hammerspoon hotkeys, slow
        // the test launch with daemon-down retries, and contend with
        // the test cases' own AudioPlayer instances on the system
        // audio session.
        if isRunningTests { return }

        bootstrap()
        hotkeys.register(handlers: [
            .speakSelectionFull: { [weak self] in self?.dispatcher.speakSelection(mode: .full) },
            .speakSelectionSummary: { [weak self] in self?.dispatcher.speakSelection(mode: .summary) },
            .readChromeArticle: { [weak self] in self?.dispatcher.readChrome() },
            .pauseResume: { [weak self] in self?.dispatcher.togglePause() },
            .stop: { [weak self] in self?.dispatcher.stop() },
        ])
        menuController.start()
        log.info("Myna launched (bundle \(Bundle.main.bundleIdentifier ?? "?"))")
    }

    /// Construct all the long-lived singletons. Called only outside
    /// of XCTest contexts.
    private func bootstrap() {
        self.settings = SettingsViewModel()
        let baseURL = settings.fullDaemonBaseURL ?? DaemonClient.defaultBaseURL
        self.client = DaemonClient(baseURL: baseURL)
        self.player = AudioPlayer()
        self.selection = SelectionService()
        self.chrome = ChromeService()
        self.dispatcher = AppDispatcher(
            client: client,
            player: player,
            selection: selection,
            chrome: chrome,
            settings: settings
        )
        self.urlHandler = URLSchemeHandler(dispatcher: dispatcher) { msg in
            Log(.urlscheme).warn(msg)
        }
        self.hotkeys = HotkeyManager()
        self.updates = UpdateController()
        self.menuController = MenuBarController(
            client: client,
            player: player,
            updates: updates
        )
        self.didBootstrap = true
    }

    /// True when the host binary is running an XCTest bundle. We use
    /// this to skip side-effectful registration (hotkeys, polling
    /// timers, audio engine creation) that the tests don't want.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // bootstrap() is skipped under XCTest, so the IUO singletons are still
        // nil at terminate time and force-unwrapping would crash the test
        // host on bundle unload. Per AUDIT_REPORT.md Lane A 🟡 #4.
        guard didBootstrap else { return }
        menuController.stop()
        hotkeys.disableAll()
        player.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Under XCTest bootstrap is skipped so urlHandler is nil; AppKit may
        // still fire open-URLs at the test host during launch.
        guard didBootstrap else { return }
        urlHandler.handle(urls)
    }
}
