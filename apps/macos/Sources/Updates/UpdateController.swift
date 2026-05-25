// UpdateController.swift — Sparkle integration. Initializes a
// SPUStandardUpdaterController with default delegates. SUFeedURL and
// SUPublicEDKey are wired through Info.plist (project.yml). Lane B
// owns those values; here we expose `checkForUpdates()` that the menu
// can invoke.
import Sparkle
import SwiftUI

@MainActor
public final class UpdateController: ObservableObject {
    public let underlyingController: SPUStandardUpdaterController

    public init(startsAutomatically: Bool = true) {
        self.underlyingController = SPUStandardUpdaterController(
            startingUpdater: startsAutomatically,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    public func checkForUpdates() {
        underlyingController.checkForUpdates(nil)
    }

    /// Expose the inner Sparkle updater so SwiftUI menus can bind to
    /// its `canCheckForUpdates` published property.
    public var updater: SPUUpdater {
        underlyingController.updater
    }
}

/// SwiftUI helper view: a menu item that reflects Sparkle's
/// canCheckForUpdates state.
public struct CheckForUpdatesMenuItem: View {
    private let controller: UpdateController
    @State private var canCheck: Bool = false

    public init(_ controller: UpdateController) {
        self.controller = controller
    }

    public var body: some View {
        Button("Check for Updates…") {
            controller.checkForUpdates()
        }
        .disabled(!canCheck)
        .onAppear {
            canCheck = controller.updater.canCheckForUpdates
        }
    }
}
