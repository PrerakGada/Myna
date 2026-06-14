// MynaApp.swift — @main entry. Wires the MenuBarExtra and Settings
// scenes to the singletons owned by AppDelegate.
//
// AppDelegate bootstraps its singletons in `applicationDidFinishLaunching`
// (and skips this entirely under XCTest), so the scene bodies here use
// `RootView`/`SettingsRootView` shims that pull the optionals out
// lazily — the views are never displayed inside a test process so the
// "not yet bootstrapped" branch is purely defensive.
import SwiftUI

@main
struct MynaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Floating now-playing pill (Lane A, v0.2.x). Declared at the App
    /// scope as a @StateObject so its lifetime matches the app. It's
    /// created in a dormant state — `attach(player:, settings:)` is
    /// called from RootMenuBarView once AppDelegate.bootstrap()
    /// completes (didBootstrap flips to true).
    @StateObject private var pillController = PillController()

    var body: some Scene {
        MenuBarExtra {
            RootMenuBarView(appDelegate: appDelegate, pillController: pillController)
        } label: {
            // RootMenuBarLabel is the menu-bar icon — always rendered
            // from app launch onward. We hand it pillController so it
            // can attach the controller as soon as bootstrap completes,
            // *without* waiting for the popover to open. The popover-
            // side RootMenuBarView also calls attach() defensively;
            // attach() is idempotent.
            RootMenuBarLabel(
                appDelegate: appDelegate,
                pillController: pillController
            )
        }
        // .window hosts the popover as a free SwiftUI surface (no NSMenu
        // chrome). v0.2.1 redesign: lets us render the custom dark
        // popover and lets DisclosureGroup-style sections survive the
        // 250ms poll-driven re-renders (which would collapse NSMenu
        // submenus in the v0.2.0 .menu style).
        .menuBarExtraStyle(.window)

        Settings {
            RootSettingsView(appDelegate: appDelegate)
        }
    }
}

/// Bird label for the MenuBarExtra. Renders the state-driven SwiftUI
/// bird while bootstrap is complete; falls back to the static SF Symbol
/// during launch / test-host.
///
/// Also the place we attach the floating-pill controller. The label
/// (unlike the popover content) is rendered from app launch onward —
/// so wiring attach() here means the always-visible pill becomes
/// visible the moment AppDelegate.bootstrap() flips didBootstrap=true,
/// rather than waiting for the user to click the menu-bar icon.
/// Without this, the "always visible" Setting was effectively "visible
/// after first menu interaction", which was a real UX bug (and the
/// reason the original pill-position bug was hard to reproduce: the
/// pill only ever showed *after* the user had clicked the icon, so
/// the un-positioned default-frame state was invisible to QA).
private struct RootMenuBarLabel: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var pillController: PillController

    var body: some View {
        Group {
            if appDelegate.didBootstrap, let controller = appDelegate.menuController {
                BootedLabel(controller: controller)
            } else {
                BirdIcon.image
            }
        }
        // Covers two cases:
        //   • didBootstrap is already true when the label first appears
        //     (e.g. SwiftUI re-installed the view after a scene rebuild)
        //   • the slower normal path where bootstrap completes
        //     asynchronously a beat after launch — onChange catches the
        //     false→true transition. attach() is idempotent so it's safe
        //     to call from both triggers.
        .onAppear { attachPillIfNeeded() }
        .onChange(of: appDelegate.didBootstrap) { _ in attachPillIfNeeded() }
    }

    /// Bootstrap the pill controller once AppDelegate's singletons
    /// exist. Mirrors RootMenuBarView.attachPillIfNeeded — kept here
    /// (instead of factored to a shared helper) because the two
    /// callers want slightly different defensive postures and the
    /// duplication is six lines.
    private func attachPillIfNeeded() {
        guard appDelegate.didBootstrap else { return }
        let player: AudioPlayer? = appDelegate.player
        let settings: SettingsViewModel? = appDelegate.settings
        guard let player, let settings else { return }
        pillController.attach(player: player, settings: settings, menuController: appDelegate.menuController)
        pillController.start()
    }
}

private struct BootedLabel: View {
    @ObservedObject var controller: MenuBarController
    var body: some View {
        BirdIconView(
            state: controller.iconState,
            suppressAnimation: PowerMonitor.shared.shouldSuppressAnimation
        )
    }
}

private struct RootMenuBarView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var pillController: PillController

    var body: some View {
        // Gate on the @Published `didBootstrap` flag so SwiftUI re-renders
        // the menu when bootstrap() completes. Reading `menuController`
        // alone wouldn't trigger an update because IUOs aren't @Published.
        if appDelegate.didBootstrap, let controller = appDelegate.menuController {
            MenuBarView(controller: controller)
                .onAppear { attachPillIfNeeded() }
        } else {
            // .window-style fallback: a small dark card with the same
            // chrome as the real popover. macOS will host this in an
            // NSWindow once MenuBarExtra opens.
            VStack(spacing: 10) {
                Text("Myna initialising…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(20)
            .frame(width: 240)
            .background(Color(red: 0.039, green: 0.039, blue: 0.047))
        }
    }

    /// Attach + start the floating-pill controller once AppDelegate
    /// has bootstrapped its singletons. Idempotent: PillController
    /// guards against re-entry. AppDelegate.player / .settings are
    /// implicitly-unwrapped optionals — bootstrap completion implies
    /// they're non-nil, but we double-check defensively because the
    /// XCTest harness skips bootstrap entirely.
    private func attachPillIfNeeded() {
        guard appDelegate.didBootstrap else { return }
        // Optional-cast through Any to read the IUO without crashing
        // if it's still nil for any reason (defensive against test
        // hosts that observed didBootstrap=true but raced ahead).
        let player: AudioPlayer? = appDelegate.player
        let settings: SettingsViewModel? = appDelegate.settings
        guard let player, let settings else { return }
        pillController.attach(player: player, settings: settings, menuController: appDelegate.menuController)
        pillController.start()
    }
}

private struct RootSettingsView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        // Pass the running AudioPlayer in as the AudioDuckable so the S09
        // voice preview can duck main playback to 30% during a sample.
        // SettingsView.audioSink is optional, so passing nil in contexts
        // where the player isn't ready is also safe.
        let isReady = appDelegate.didBootstrap
        let viewModel = appDelegate.settings
        let client = appDelegate.client
        if isReady, let viewModel, let client {
            SettingsView(viewModel: viewModel, client: client, audioSink: appDelegate.player)
        } else {
            Text("Settings unavailable in this context.").padding()
        }
    }
}
