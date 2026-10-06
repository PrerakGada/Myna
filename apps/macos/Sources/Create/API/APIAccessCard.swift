// APIAccessCard.swift — who can reach the API.
//
// By default the daemon listens on 127.0.0.1 only and nothing here needs
// a key. "Allow devices on my network" rebinds it to the LAN; from then
// on other devices must send the key, and even with it they reach only
// the /v1 speech endpoints — never playback, settings or render jobs
// (the daemon's middleware enforces that, RENDER_API.md § 4). The card
// says exactly that, next to the switch.
import SwiftUI

struct APIAccessCard: View {
    @ObservedObject var model: APIPaneModel

    @State private var revealKey = false
    @State private var confirmRegenerate = false

    private var settings: APISettings? { model.settings }
    private var lanEnabled: Bool { settings?.lanEnabled ?? false }
    private var controlsLocked: Bool { settings == nil || model.accessBusy || model.isRestarting }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Access")
                    .padding(.bottom, 8)
                lanRow
                if model.isRestarting {
                    restartingNote
                } else if model.status == .restartNeeded {
                    Text("Saved, but not applied until the voice service restarts. Restart it from the Engine page.")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                DashDivider()
                lanURLsRow
                DashDivider()
                keyRow
                DashDivider()
                loopbackNote
                if let error = model.accessError {
                    Text(error)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.negative)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
        }
        .confirmationDialog(
            "Make a new API key?",
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            Button("Make a new key", role: .destructive) {
                Task { await model.regenerateKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The current key stops working at once. Every device and app that uses it gets "
                    + "\"unauthorized\" until you give it the new one. Apps on this Mac aren't affected."
            )
        }
    }

    private var lanRow: some View {
        DashRow(
            "Allow devices on my network",
            help: "Anyone on this network who has the key can make audio with this Mac's voice engine. "
                + "They get the file back; they can't play anything on this Mac or change its settings."
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { lanEnabled },
                    set: { wanted in Task { await model.setLANEnabled(wanted) } }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(controlsLocked)
        }
    }

    private var restartingNote: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text("Restarting Myna's voice service to apply this. It takes a few seconds.")
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder private var lanURLsRow: some View {
        let urls = settings?.lanUrls ?? []
        VStack(alignment: .leading, spacing: 6) {
            Text(lanEnabled && !(settings?.restartPending ?? false) ? "Other devices use" : "Other devices would use")
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.body)
            if urls.isEmpty {
                Text(
                    settings == nil
                        ? "Not known until the voice service answers."
                        : "This Mac has no network address right now. Connect to Wi-Fi or Ethernet."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
            } else {
                ForEach(urls, id: \.self) { url in
                    APICopyField(value: url, dimmed: !lanEnabled)
                }
                if !lanEnabled {
                    Text("Not reachable until you allow devices on your network.")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                } else {
                    Text("If the macOS firewall is on, it may ask whether Myna Voice can accept incoming connections.")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("API key")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                Spacer(minLength: 8)
                if settings?.apiKey != nil {
                    Button(revealKey ? "Hide" : "Reveal") { revealKey.toggle() }
                        .buttonStyle(.borderless)
                        .font(DashboardDesign.captionFont)
                    Button("New key…") { confirmRegenerate = true }
                        .buttonStyle(.borderless)
                        .font(DashboardDesign.captionFont)
                        .disabled(controlsLocked)
                }
            }
            if let key = settings?.apiKey {
                APICopyField(value: key, display: revealKey ? key : APISnippets.maskedKey(key))
                Text("Other devices send it as ")
                    .font(DashboardDesign.captionFont)
                    .foregroundColor(DashboardDesign.secondary)
                    + APIText.code("Authorization: Bearer <key>")
                    + Text(". Copy always copies the whole key.")
                    .font(DashboardDesign.captionFont)
                    .foregroundColor(DashboardDesign.secondary)
            } else {
                Text(settings == nil ? "Not known until the voice service answers." : "The voice service didn't send a key.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var loopbackNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(DashboardDesign.positive)
                .frame(width: 14)
            Text(
                "Apps and scripts on this Mac never need the key: requests from 127.0.0.1 are always allowed. "
                    + "OpenAI SDKs insist on some key, so give them any text."
            )
            .font(DashboardDesign.captionFont)
            .foregroundStyle(DashboardDesign.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }
}
