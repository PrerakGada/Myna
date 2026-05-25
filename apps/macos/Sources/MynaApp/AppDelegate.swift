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
import ApplicationServices
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
    /// @Published so the MenuBarExtra view re-renders when bootstrap
    /// completes. Plain stored IUOs don't fire objectWillChange, so the
    /// menu was permanently stuck on the "Myna initialising…" fallback.
    @Published private(set) var didBootstrap = false
    private let log = Log(.app)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // belt-and-braces with LSUIElement.

        // Diagnostic stderr lines complement the OSLog so the launch path
        // is visible even when Console.app hasn't ingested the subsystem.
        FileHandle.standardError.write(Data("[Myna] applicationDidFinishLaunching fired\n".utf8))

        // Don't initialise live audio/hotkey/poll machinery when the
        // binary is hosting an XCTest bundle — those side effects would
        // fight with the user's running v1 hammerspoon hotkeys, slow
        // the test launch with daemon-down retries, and contend with
        // the test cases' own AudioPlayer instances on the system
        // audio session.
        if isRunningTests {
            FileHandle.standardError.write(Data("[Myna] isRunningTests=true → skipping bootstrap\n".utf8))
            return
        }

        FileHandle.standardError.write(Data("[Myna] bootstrapping…\n".utf8))
        bootstrap()
        FileHandle.standardError.write(Data("[Myna] bootstrap returned; registering hotkeys\n".utf8))

        // Trigger the Accessibility prompt if we don't already have it.
        // Without Accessibility, CGEvent.post silently no-ops when
        // SelectionService simulates Cmd+C — the hotkey fires, the
        // pasteboard never fills, and nothing plays. The first launch
        // MUST surface the system prompt so the user can grant it; macOS
        // doesn't show the dialog automatically the way it does for
        // microphone / camera / contacts.
        promptForAccessibilityIfNeeded()
        hotkeys.register(handlers: [
            .speakSelectionFull: { [weak self] in self?.dispatcher.speakSelection(mode: .full) },
            .speakSelectionSummary: { [weak self] in self?.dispatcher.speakSelection(mode: .summary) },
            .readChromeArticle: { [weak self] in self?.dispatcher.readChrome() },
            .pauseResume: { [weak self] in self?.dispatcher.togglePause() },
            .stop: { [weak self] in self?.dispatcher.stop() },
        ])
        menuController.start()
        FileHandle.standardError.write(Data("[Myna] launch complete\n".utf8))
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
    ///
    /// IMPORTANT: only the env-var check is reliable. macOS 15+ auto-loads
    /// `XCTestSupport.framework` into every app's address space for the
    /// in-process testing infrastructure, which makes `NSClassFromString("XCTestCase")`
    /// return non-nil even in normal Finder launches. Including that check
    /// in the OR made the bootstrap permanently skip in shipped builds —
    /// users saw "Myna initialising…" forever.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Show the Accessibility-required system prompt if Myna isn't trusted
    /// yet. `AXIsProcessTrustedWithOptions` with the prompt option set
    /// either:
    ///   - returns true silently (already trusted), or
    ///   - returns false and shows the macOS "Myna would like to control
    ///     your computer" alert that deep-links to System Settings.
    /// After the user grants it, they need to relaunch Myna for the
    /// TCC change to take effect in this process.
    private func promptForAccessibilityIfNeeded() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        FileHandle.standardError.write(Data("[Myna] AXIsProcessTrusted=\(trusted)\n".utf8))
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
