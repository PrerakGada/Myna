// APIPane.swift — the API page: use Myna's voice from any other app,
// script or device.
//
// The headline is that the daemon speaks OpenAI's text-to-speech API, so
// the page leads with that and the address to paste, then gets more
// specific as you scroll: examples, a live "Try it", the request log,
// who can reach it, the endpoint table, and the app's other entry points
// (myna:// links and the CLI).
//
// Contract: docs/native-app/RENDER_API.md §§ 1, 4. The pane talks to the
// daemon through RenderClient and DaemonClient only; APIPaneModel holds
// the state, and the snippet/log/restart logic is pure and unit-tested.
import AppKit
import SwiftUI

struct APIPane: View {
    let context: DashboardContext
    @ObservedObject var launcher: DashboardLauncher

    @StateObject private var model: APIPaneModel
    @StateObject private var tryIt: APITryItModel

    init(context: DashboardContext, launcher: DashboardLauncher) {
        self.context = context
        self.launcher = launcher
        let render = RenderClient.shared
        _model = StateObject(wrappedValue: APIPaneModel(
            render: render,
            daemon: context.client,
            isOnScreen: { APIPane.dashboardIsOnScreen() }
        ))
        _tryIt = StateObject(wrappedValue: APITryItModel(render: render))
    }

    var body: some View {
        PaneScaffold(
            title: DashboardPane.api.title,
            subtitle: DashboardPane.api.subtitle
        ) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label(model.refreshing ? "Checking…" : "Recheck", systemImage: "arrow.clockwise")
            }
            .disabled(model.refreshing || model.isRestarting)
        } content: {
            APIPaneCards(model: model, tryIt: tryIt)
        }
        .task { await model.refresh() }
        .task { await model.pollLoop() }
    }

    /// `http://127.0.0.1:8766/v1` → `http://127.0.0.1:8766`.
    nonisolated static func origin(of baseURL: String) -> String {
        baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
    }

    /// The request log is polled only while someone can see it: the
    /// Dashboard window is open, not minimised and not fully covered.
    @MainActor
    static func dashboardIsOnScreen() -> Bool {
        NSApp.windows.contains { window in
            window is DashboardWindow && window.isVisible && window.occlusionState.contains(.visible)
        }
    }
}

/// The pane's cards in reading order. Separate from APIPane so it can be
/// built without a DashboardContext (the offscreen layout snapshots in
/// APIPaneSnapshotTests use it).
struct APIPaneCards: View {
    @ObservedObject var model: APIPaneModel
    @ObservedObject var tryIt: APITryItModel

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
            APIStatusCard(model: model)
            APIQuickStartCard(model: model)
            APITryItCard(model: model, tryIt: tryIt)
            APILogCard(model: model)
            APIAccessCard(model: model)
            APIEndpointsCard(origin: APIPane.origin(of: model.baseURL))
            APIOtherWaysCard()
        }
    }
}
