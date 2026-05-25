// AppDelegate.swift — system event hooks. Phase 0 skeleton; Lane A workers expand.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // belt-and-braces with LSUIElement
    }

    // Lane A URLSchemeHandler will own this:
    func application(_ application: NSApplication, open urls: [URL]) {
        // delegate to URLSchemeHandler.handle(urls)
    }
}
