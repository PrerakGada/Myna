// MynaApp.swift — @main entry. Phase 0 skeleton; Lane A workers expand this.
import SwiftUI

@main
struct MynaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Myna", systemImage: "bird") {
            // Lane A: replace this with MenuBarView once implemented.
            Text("Myna v0.1 — Phase 0 skeleton")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            // Lane A: replace with SettingsView.
            Text("Settings — coming in Lane A").padding()
        }
    }
}
