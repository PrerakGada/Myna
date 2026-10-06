// ClaudeHandsFreeCard.swift — the Reading pane's "Claude Code when you're
// away" card: auto-read replies, spoken "needs you" alerts, what counts as
// away, and the microphone hold.
//
// Its own file so the Reading pane includes it with one line, and binds the
// hands-free keys (HandsFreeKey) directly with @AppStorage instead of
// growing SettingsViewModel. It also checks, read-only, whether Claude Code
// has Myna's Notification hook yet: an app update doesn't reinstall the
// hook, so without setup running again alerts would never arrive.
import SwiftUI

struct ClaudeHandsFreeCard: View {
    @AppStorage(HandsFreeKey.autoReadWhenAway) private var autoRead = false
    @AppStorage(HandsFreeKey.speakAlerts) private var speakAlerts = false
    @AppStorage(HandsFreeKey.alertsAtDesk) private var alertsAtDesk = false
    @AppStorage(HandsFreeKey.awayWhenLocked) private var whenLocked = true
    @AppStorage(HandsFreeKey.awayWhenIdle) private var whenIdle = true
    @AppStorage(HandsFreeKey.awayIdleMinutes) private var idleMinutes = AwayPolicy.defaultIdleMinutes
    @AppStorage(HandsFreeKey.awayWhenNotFrontmost) private var whenNotFrontmost = false
    @AppStorage(HandsFreeKey.holdDuringCalls) private var holdDuringCalls = true
    @State private var hookStatus: ClaudeHookStatus = .installed

    private var anyOn: Bool { autoRead || speakAlerts }
    private var noAwaySignal: Bool { !whenLocked && !whenIdle && !whenNotFrontmost }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 0) {
                DashSectionTitle("Claude Code when you're away")
                    .padding(.bottom, 4)
                Text("At your desk nothing changes: a reply waits in the pill or card until you press "
                    + "Play. These only speak while you're away, one thing at a time, and never over "
                    + "something you're already listening to.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                featureRows
                if anyOn, hookStatus == .needsUpdate { hookNotice }
                DashDivider()
                awayRows
            }
        }
        .onAppear { hookStatus = ClaudeHookStatus.check() }
    }

    @ViewBuilder private var featureRows: some View {
        DashRow(
            "Read replies aloud while I'm away",
            help: "Each finished reply is read in turn, starting with its project's name. If you "
                + "come back mid-read, Myna finishes the passage it's on and stops; the rest stays "
                + "in the pill or card, marked “Partly heard”."
        ) {
            toggle($autoRead)
        }
        DashDivider()
        DashRow(
            "Say when a session needs you",
            help: "A short line such as “myna needs you, permission to run a command” when Claude "
                + "Code asks for permission or is waiting on you. The notice also appears in the "
                + "pill or card."
        ) {
            toggle($speakAlerts)
        }
        DashDivider()
        DashRow(
            "Say it at my desk too",
            help: "Off: alerts are spoken only while you're away, and just shown while you're here."
        ) {
            toggle($alertsAtDesk).disabled(!speakAlerts)
        }
    }

    @ViewBuilder private var awayRows: some View {
        Text("You count as away when any of these is true")
            .font(DashboardDesign.bodyFont)
            .foregroundStyle(DashboardDesign.body)
            .padding(.top, 10)
            .padding(.bottom, 2)
        DashRow("The screen is locked or the display is asleep") {
            toggle($whenLocked).disabled(!anyOn)
        }
        DashDivider()
        DashRow(
            "No keyboard or mouse input for \(idleMinutes) min",
            help: "Reading something on screen without touching anything counts too, so pick a "
                + "time longer than you usually read for."
        ) {
            HStack(spacing: 10) {
                Stepper("", value: $idleMinutes, in: AwayPolicy.idleMinutesRange)
                    .labelsHidden()
                    .disabled(!anyOn || !whenIdle)
                toggle($whenIdle).disabled(!anyOn)
            }
        }
        DashDivider()
        DashRow(
            "Claude Code's window isn't in front",
            help: "Off by default, because many people read replies in another window. Myna checks "
                + "the app the session runs in — iTerm, Terminal, VS Code — so it needs the "
                + "updated Claude Code hook."
        ) {
            toggle($whenNotFrontmost).disabled(!anyOn)
        }
        DashDivider()
        DashRow(
            "Wait while the microphone is in use",
            help: "Holds speech while another app is using your microphone: a call, and dictation "
                + "apps too. A passage cut off by the hold starts again once the microphone is free."
        ) {
            toggle($holdDuringCalls).disabled(!anyOn)
        }
        if anyOn, noAwaySignal {
            Text("With all three away signals off, Myna never counts you as away, so it won't "
                + "read anything aloud.")
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var hookNotice: some View {
        DashRow(
            "Claude Code isn't sending Myna its prompts yet",
            help: "Alerts come from a Claude Code hook that this version of Myna adds. Run setup "
                + "again to install it (everything already installed is kept), then restart your "
                + "Claude Code sessions."
        ) {
            Button("Run setup") { _ = SetupLauncher.shared.present() }
        }
    }

    private func toggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
    }
}

/// Whether Claude Code has Myna's Notification hook registered. Read-only:
/// the only thing that ever writes Claude Code's settings is setup.
enum ClaudeHookStatus: Equatable {
    case installed
    /// Claude Code is installed but has no Myna Notification hook.
    case needsUpdate
    /// No ~/.claude — nothing to connect.
    case noClaudeCode

    static func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClaudeHookStatus {
        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .noClaudeCode
        }
        let url = claudeDir.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["Notification"] as? [Any]
        else { return .needsUpdate }
        let registered = groups.contains { group in
            let entries = (group as? [String: Any])?["hooks"] as? [Any] ?? []
            return entries.contains { entry in
                ((entry as? [String: Any])?["command"] as? String)?.contains("myna-cc-announce.py") ?? false
            }
        }
        return registered ? .installed : .needsUpdate
    }
}
