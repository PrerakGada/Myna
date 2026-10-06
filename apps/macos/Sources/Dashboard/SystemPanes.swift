// SystemPanes.swift — Logs and Account & Data. (Engine lives in
// EnginePane.swift.)
//
// Account & Data is the honest version of the "user accounts and iCloud
// syncing" idea: Myna has no server, no sign-in and no CloudKit
// container, so rather than mock one up this pane tells the truth about
// where the data lives, how big it is, what leaves the Mac (nothing but
// article fetches and update checks), and gives real export and delete
// controls. When sync exists, it lands here.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Logs

struct LogsPane: View {
    var body: some View {
        PaneScaffold(
            title: DashboardPane.logs.title,
            subtitle: DashboardPane.logs.subtitle,
            scrolls: false
        ) {
            EmptyView()
        } content: {
            LogViewerView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Account & data

struct AccountPane: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var updates: UpdateController
    @ObservedObject var settings: SettingsViewModel

    @AppStorage("dev.myna.app.historyRetentionDays") private var retentionDays: Int = 0
    @State private var confirmingClear = false

    private static let retentionOptions: [(label: String, days: Int)] = [
        ("Keep everything", 0),
        ("30 days", 30),
        ("90 days", 90),
        ("1 year", 365),
    ]

    var body: some View {
        PaneScaffold(
            title: DashboardPane.account.title,
            subtitle: DashboardPane.account.subtitle
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                identityCard
                dataCard
                networkCard
                aboutCard
            }
        }
    }

    // MARK: identity

    private var identityCard: some View {
        DashCard {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DashboardDesign.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Signed in as \(NSFullUserName())")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DashboardDesign.title)
                        DashBadge("This Mac only", tint: DashboardDesign.secondary)
                    }
                    Text(
                        "Myna has no account system. There is no Myna server, nothing to sign "
                            + "in to, and nothing uploaded — your reading history, voices and "
                            + "shortcuts live in files on this Mac and nowhere else."
                    )
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Sync across your Macs is not built yet. When it is, it will appear here "
                            + "and be opt-in."
                    )
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: data

    private var dataCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Your data")
                    .padding(.bottom, 8)
                DashRow("Reads recorded") {
                    Text("\(history.events.count)")
                        .font(DashboardDesign.bodyFont.monospacedDigit())
                        .foregroundStyle(DashboardDesign.body)
                }
                DashDivider()
                DashRow("History file size") {
                    Text(Self.byteString(history.fileSizeBytes))
                        .font(DashboardDesign.bodyFont.monospacedDigit())
                        .foregroundStyle(DashboardDesign.body)
                }
                DashDivider()
                DashRow("Stored at", help: history.fileURL.path) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([history.fileURL])
                    }
                }
                DashDivider()
                DashRow(
                    "Keep history for",
                    help: "Older reads are removed the next time Myna launches."
                ) {
                    Picker("", selection: $retentionDays) {
                        ForEach(Self.retentionOptions, id: \.days) { option in
                            Text(option.label).tag(option.days)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: retentionDays) { newValue in
                        history.prune(olderThanDays: newValue)
                    }
                }
                DashDivider()
                DashRow(
                    "Export",
                    help: "JSON is a complete backup including the text of every read. CSV is "
                        + "for spreadsheets and deliberately leaves the text out."
                ) {
                    HStack(spacing: 6) {
                        Button("JSON…") { export(.json) }
                        Button("CSV…") { export(.commaSeparatedText) }
                    }
                    .disabled(history.events.isEmpty)
                }
                DashDivider()
                DashRow(
                    "Delete everything",
                    help: "Removes every recorded read from this Mac. Cannot be undone."
                ) {
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Text("Delete history")
                    }
                    .disabled(history.events.isEmpty)
                    .confirmationDialog(
                        "Delete all \(history.events.count) records?",
                        isPresented: $confirmingClear,
                        titleVisibility: .visible
                    ) {
                        Button("Delete everything", role: .destructive) { history.clear() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
    }

    // MARK: network

    private var networkCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 10) {
                DashSectionTitle("What leaves this Mac")
                NetworkRow(
                    systemImage: "waveform",
                    title: "Speech synthesis",
                    detail: "Runs entirely on this Mac, against the local voice engine on "
                        + "127.0.0.1. Your text is never sent anywhere.",
                    tint: DashboardDesign.positive)
                NetworkRow(
                    systemImage: "globe",
                    title: "Article reads",
                    detail: "When you read a Chrome tab, Myna fetches that page's own URL to "
                        + "extract its text. That request goes to the site you are reading.",
                    tint: DashboardDesign.info)
                NetworkRow(
                    systemImage: "arrow.down.circle",
                    title: "Update checks",
                    detail: "Sparkle asks GitHub for the appcast. No identifiers, no usage data.",
                    tint: DashboardDesign.info)
            }
        }
    }

    // MARK: about

    private var aboutCard: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("About")
                    .padding(.bottom, 8)
                DashRow("Version") {
                    Text(Self.versionString).foregroundStyle(DashboardDesign.body)
                }
                DashDivider()
                DashRow("Updates") {
                    Button("Check now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
                DashDivider()
                DashRow("Website") {
                    Button("myna.prerakgada.in") {
                        if let url = URL(string: "https://myna.prerakgada.in") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                DashDivider()
                DashRow(
                    "Reset all settings",
                    help: "Puts every preference back to its default. Your history is not touched."
                ) {
                    Button("Reset") { settings.resetAll() }
                }
            }
        }
    }

    // MARK: helpers

    static var versionString: String {
        let short =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }

    static func byteString(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func export(_ type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue =
            "myna-history-\(stamp).\(type == .json ? "json" : "csv")"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if type == .json {
            try? history.exportJSON()?.write(to: url, options: .atomic)
        } else {
            try? Data(history.exportCSV().utf8).write(to: url, options: .atomic)
        }
    }
}

private struct NetworkRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                Text(detail)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
