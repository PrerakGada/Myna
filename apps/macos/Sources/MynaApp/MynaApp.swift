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

    var body: some Scene {
        MenuBarExtra {
            RootMenuBarView(appDelegate: appDelegate)
        } label: {
            RootMenuBarLabel(appDelegate: appDelegate)
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
private struct RootMenuBarLabel: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if appDelegate.didBootstrap, let controller = appDelegate.menuController {
            BootedLabel(controller: controller)
        } else {
            BirdIcon.image
        }
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

    var body: some View {
        // Gate on the @Published `didBootstrap` flag so SwiftUI re-renders
        // the menu when bootstrap() completes. Reading `menuController`
        // alone wouldn't trigger an update because IUOs aren't @Published.
        if appDelegate.didBootstrap, let controller = appDelegate.menuController {
            MenuBarView(controller: controller)
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
