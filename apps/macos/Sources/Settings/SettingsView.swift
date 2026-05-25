// SettingsView.swift — TabView with the four Settings tabs.
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let client: DaemonClient

    public init(viewModel: SettingsViewModel, client: DaemonClient) {
        self.viewModel = viewModel
        self.client = client
    }

    public var body: some View {
        TabView {
            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            VoiceTab(viewModel: viewModel, client: client)
                .tabItem { Label("Voice", systemImage: "waveform") }
            DaemonTab(viewModel: viewModel, client: client)
                .tabItem { Label("Daemon", systemImage: "server.rack") }
            AdvancedTab(viewModel: viewModel)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540, height: 400)
    }
}
