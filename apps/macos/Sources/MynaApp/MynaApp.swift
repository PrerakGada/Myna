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
            BirdIcon.image
        }
        .menuBarExtraStyle(.menu)

        Settings {
            RootSettingsView(appDelegate: appDelegate)
        }
    }
}

private struct RootMenuBarView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if let controller = appDelegate.menuController {
            MenuBarView(controller: controller)
        } else {
            Text("Myna initialising…").padding()
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct RootSettingsView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if let viewModel = appDelegate.settings, let client = appDelegate.client {
            SettingsView(viewModel: viewModel, client: client)
        } else {
            Text("Settings unavailable in this context.").padding()
        }
    }
}
