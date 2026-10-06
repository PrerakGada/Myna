// APIReferenceCards.swift — the endpoint table and the "Other ways in"
// card (myna:// routes and the myna CLI). Content lives in
// APIReference; these views only lay it out.
import AppKit
import SwiftUI

struct APIEndpointsCard: View {
    /// `http://127.0.0.1:8766` — the base URL without `/v1`.
    let origin: String

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    DashSectionTitle("Endpoints")
                    Spacer(minLength: 8)
                    Button {
                        NSWorkspace.shared.open(APIReference.docsURL)
                    } label: {
                        Label("Full reference", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help(APIReference.docsURL.absoluteString)
                }
                Text(
                    "Paths are relative to \(origin). Use /v1/audio/speech for anything up to a few "
                        + "pages; for articles and books, start a render job and poll it. Errors on /v1 use "
                        + "OpenAI's error shape, so OpenAI SDKs report them properly."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(APIReference.endpoints) { endpoint in
                        row(endpoint)
                        if endpoint.id != APIReference.endpoints.last?.id { DashDivider() }
                    }
                }

                Text("Other devices on your network (when allowed) can reach only the /v1 endpoints. Render jobs answer this Mac only.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ endpoint: APIReference.Endpoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                APIMethodTag(method: endpoint.method)
                Text(endpoint.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DashboardDesign.title)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.summary)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let params = endpoint.params {
                    Text(params)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DashboardDesign.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

struct APIOtherWaysCard: View {
    @State private var cliPath: String? = APIReference.installedCLI()

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 14) {
                DashSectionTitle("Other ways in")
                section(
                    title: "myna:// links",
                    detail: "Control the app itself. Open one from Terminal with open \"myna://stop\", or from "
                        + "Shortcuts with Open URLs. There's deliberately no link that speaks text you pass in, since "
                        + "any app can open a myna:// link; use the HTTP API for that.",
                    entries: APIReference.urlRoutes
                )
                DashDivider()
                section(
                    title: "The myna command",
                    detail: cliDetail,
                    entries: APIReference.cliCommands
                )
            }
        }
    }

    private var cliDetail: String {
        let base = "Speaks through the voice service directly, so it doesn't appear in the menu bar or History."
        if let cliPath {
            return "Installed at \(cliPath). " + base
        }
        return "Not installed on this Mac: it comes with the Homebrew version of Myna, not the downloaded app. " + base
    }

    private func section(title: String, detail: String, entries: [APIReference.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DashboardDesign.title)
            Text(detail)
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(entries) { entry in
                    HStack(alignment: .center, spacing: 12) {
                        APICopyField(value: entry.value, fontSize: 11)
                            .frame(width: 290)
                        Text(entry.summary)
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
