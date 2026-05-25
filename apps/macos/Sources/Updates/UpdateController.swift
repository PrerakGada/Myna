// UpdateController.swift — Sparkle 2 integration.
//
// Owns the SPUStandardUpdaterController and publishes whether the
// "Check for Updates…" menu item should be enabled.
//
// Lane A's MenuBar wires this into the menu via either:
//   • `@EnvironmentObject var updates: UpdateController` (injected at the
//     `MenuBarExtra` scene), or
//   • `UpdateController.shared` (singleton fallback) if Lane A would rather
//     not thread the environment through every preview.
//
// Either way, the contract is small:
//   updates.checkForUpdates()        — show the "checking" dialog now
//   updates.canCheckForUpdates       — bind to .disabled() on the menu item
//
// The appcast URL and EdDSA public key live in Info.plist (project.yml's
// SUFeedURL + SUPublicEDKey). Sparkle reads them at init time — no extra
// wiring needed here.

import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle's updater. One instance per app, accessed either via
/// `@EnvironmentObject` (preferred) or `UpdateController.shared`.
@MainActor
public final class UpdateController: ObservableObject {

    /// Singleton fallback for callers that can't easily receive an env object
    /// (e.g. AppDelegate-era code, debug shortcuts, URL scheme handler).
    /// Lane A may also choose to inject this as an `@EnvironmentObject`.
    public static let shared = UpdateController()

    /// Mirrors `updater.canCheckForUpdates`. Bind to `.disabled(!canCheckForUpdates)`
    /// on the "Check for Updates…" menu item.
    @Published public private(set) var canCheckForUpdates: Bool = false

    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    public init() {
        // `startingUpdater: true` makes Sparkle start its scheduled-check
        // timer immediately. SUEnableAutomaticChecks in Info.plist controls
        // whether it actually fetches anything.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // Mirror `updater.canCheckForUpdates` into our @Published wrapper.
        // Sparkle exposes this as a KVO-observable property on SPUUpdater.
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)
    }

    /// Show Sparkle's "checking for updates" dialog. Safe to call from any
    /// thread because `@MainActor` hops us back to main.
    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// The raw updater — exposed for advanced cases (e.g. settings UI that
    /// wants to bind `SUEnableAutomaticChecks`). Most callers should prefer
    /// `checkForUpdates()` and `canCheckForUpdates`.
    public var updater: SPUUpdater { controller.updater }
}

/// SwiftUI menu item that calls `UpdateController.checkForUpdates()` and
/// disables itself when Sparkle reports it can't currently check (e.g. an
/// update is already in progress, or the network is offline). Lane A's
/// `MenuBarView` references this as `CheckForUpdatesMenuItem(controller.updates)`.
public struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var controller: UpdateController

    public init(_ controller: UpdateController) {
        self.controller = controller
    }

    public var body: some View {
        Button("Check for Updates…") { controller.checkForUpdates() }
            .disabled(!controller.canCheckForUpdates)
    }
}
