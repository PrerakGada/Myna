// APIQuickStartCard.swift — copy-paste examples in tabs, filled with the
// real base URL, a real voice of the active engine and a format this Mac
// can encode (APISnippets does the generating).
//
// With network access on, a switch shows the version another device
// would use: the LAN address plus the key. The key is masked on screen
// and Copy carries the real one, so a screen-share doesn't leak it.
import SwiftUI

struct APIQuickStartCard: View {
    @ObservedObject var model: APIPaneModel

    /// Fixes the tab instead of the remembered one (layout snapshots).
    let pinnedTab: APISnippets.Kind?

    @AppStorage("dev.myna.app.api.snippetTab") private var tabRaw = APISnippets.Kind.curl.rawValue
    @State private var showNetworkVersion = false

    private var tab: APISnippets.Kind { pinnedTab ?? APISnippets.Kind(rawValue: tabRaw) ?? .curl }

    private static let networkNote =
        " Uses this Mac's network address and the API key, hidden on screen; Copy includes it."

    init(model: APIPaneModel, pinnedTab: APISnippets.Kind? = nil, showNetworkVersion: Bool = false) {
        self.model = model
        self.pinnedTab = pinnedTab
        _showNetworkVersion = State(initialValue: showNetworkVersion)
    }

    private var lanURL: String? {
        guard let settings = model.settings, settings.lanEnabled else { return nil }
        return APISnippets.preferredLANURL(settings.lanUrls)
    }

    private var networkAvailable: Bool { lanURL != nil && model.settings?.apiKey != nil }
    private var usingNetwork: Bool { showNetworkVersion && networkAvailable }

    /// `masked`: the version drawn on screen; otherwise the one copied.
    private func context(masked: Bool) -> APISnippets.Context {
        var ctx = APISnippets.Context(
            baseURL: model.baseURL,
            voice: model.snippetVoice,
            format: model.snippetFormat,
            apiKey: nil
        )
        if usingNetwork, let lanURL, let key = model.settings?.apiKey {
            ctx.baseURL = lanURL
            ctx.apiKey = masked ? APISnippets.maskedKey(key) : key
        }
        return ctx
    }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    DashSectionTitle("Quick start")
                    Spacer(minLength: 8)
                    if networkAvailable {
                        Toggle("Version for other devices", isOn: $showNetworkVersion)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.secondary)
                    }
                }

                Picker("", selection: Binding(get: { tab.rawValue }, set: { tabRaw = $0 })) {
                    ForEach(APISnippets.Kind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(tab.caption + (usingNetwork ? Self.networkNote : ""))
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                tabContent
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        let shown = context(masked: true)
        let copied = context(masked: false)
        switch tab {
        case .curl, .python, .node, .fetch, .shell:
            APICodeBlock(
                code: APISnippets.snippet(tab, shown),
                language: language(tab),
                copyText: APISnippets.snippet(tab, copied)
            )
        case .shortcuts:
            shortcuts(shown: shown, copied: copied)
        case .apps:
            apps(shown: shown, copied: copied)
        }
    }

    private func language(_ kind: APISnippets.Kind) -> String {
        switch kind {
        case .curl, .shell: return "shell"
        case .python: return "python"
        case .node, .fetch: return "javascript"
        case .shortcuts, .apps: return ""
        }
    }

    // MARK: - Shortcuts

    private func shortcuts(shown: APISnippets.Context, copied: APISnippets.Context) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let steps = APISnippets.shortcutSteps(shown)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DashboardDesign.accent)
                        .frame(width: 14, alignment: .trailing)
                    Text(step)
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            APICopyField(value: copied.speechURL, display: shown.speechURL)
            if !usingNetwork {
                Text(
                    networkAvailable
                        ? "For an iPhone or iPad, switch on Version for other devices above."
                        : "For an iPhone or iPad, allow devices on your network under Access first. The "
                            + "shortcut then uses this Mac's network address and the key."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Apps

    private func apps(shown: APISnippets.Context, copied: APISnippets.Context) -> some View {
        let shownFields = APISnippets.appFields(shown)
        let copiedFields = APISnippets.appFields(copied)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(shownFields.indices, id: \.self) { index in
                let field = shownFields[index]
                let real = copiedFields[index]
                HStack(alignment: .top, spacing: 12) {
                    Text(field.label)
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.body)
                        .frame(width: 70, alignment: .leading)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        APICopyField(value: real.value, display: field.value)
                        if let note = field.note {
                            Text(note)
                                .font(DashboardDesign.captionFont)
                                .foregroundStyle(DashboardDesign.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            DashDivider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Open WebUI")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DashboardDesign.title)
                Text(
                    "Admin Panel → Settings → Audio. Set the text-to-speech engine to OpenAI, then enter "
                        + "the base URL, key, voice and model above. If Open WebUI runs in Docker, "
                        + "127.0.0.1 is the container itself: use host.docker.internal instead."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
