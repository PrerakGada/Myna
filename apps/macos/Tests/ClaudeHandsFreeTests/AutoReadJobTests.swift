// AutoReadJobTests.swift — which arriving registry items become spoken jobs
// (settings, away, freshness, partly-heard), what the pill/toast/card are
// allowed to show, and the read-only Claude Code hook check.
import XCTest

@testable import Myna

@MainActor
final class AutoReadJobTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var nowMs: Int { Int(now.timeIntervalSince1970 * 1000) }

    private func reply(
        id: String = "u_1", ageSeconds: Int = 2, partlyHeard: Bool? = nil, text: String = "It **shipped**. Tests pass."
    ) -> RegistryV2Item {
        RegistryV2Item(
            id: id, source: "claude-code", projectId: "myna", title: "It shipped.", text: text,
            announcedAtMs: nowMs - ageSeconds * 1000, ttlS: 600, kind: "reply",
            sessionId: "sess-1", hostBundleId: "com.googlecode.iterm2", partlyHeard: partlyHeard)
    }

    private func alert(type: String = "permission_prompt") -> RegistryV2Item {
        RegistryV2Item(
            id: "a_1", source: "claude-code", projectId: "myna",
            title: "Claude needs your permission to use Bash", text: "Claude needs your permission to use Bash",
            announcedAtMs: nowMs - 1000, ttlS: 600, kind: "attention", sessionId: "sess-1",
            notificationType: type, hostBundleId: "com.googlecode.iterm2")
    }

    private func config(autoRead: Bool = true, alerts: Bool = true, atDesk: Bool = false) -> HandsFreeSettings {
        var settings = HandsFreeSettings()
        settings.autoReadWhenAway = autoRead
        settings.speakAlerts = alerts
        settings.alertsAtDesk = atDesk
        return settings
    }

    private func job(
        _ item: RegistryV2Item, _ settings: HandsFreeSettings, away: Bool = true, bold: Bool = false
    ) -> AutoReadJob? {
        AutoReadController.job(for: item, config: settings, boldClaimsOnly: bold, now: now) { _ in away }
    }

    func test_reply_while_away_becomes_a_prefixed_reply_job() {
        let made = job(reply(), config())
        XCTAssertEqual(made?.kind, .reply)
        XCTAssertEqual(made?.prefix, "From myna.")
        XCTAssertEqual(made?.passages, ["It **shipped**. Tests pass."])
        XCTAssertEqual(made?.sessionKey, "sess-1")
        XCTAssertEqual(made?.hostBundleId, "com.googlecode.iterm2")
        XCTAssertEqual(made?.requiresAway, true)
    }

    func test_reply_at_desk_is_left_to_the_pill() {
        XCTAssertNil(job(reply(), config(), away: false))
    }

    func test_reply_with_auto_read_off_is_ignored() {
        XCTAssertNil(job(reply(), config(autoRead: false)))
    }

    func test_bold_claims_setting_applies_to_auto_read_too() {
        let claims = BoldClaims.spokenText(from: reply().text ?? "")
        XCTAssertNotNil(claims)
        XCTAssertEqual(job(reply(), config(), bold: true)?.passages, claims.map { [$0] })
    }

    func test_stale_and_partly_heard_items_are_never_auto_read() {
        XCTAssertNotNil(job(reply(ageSeconds: 120), config()), "a slow poll while locked still counts")
        XCTAssertNil(job(reply(ageSeconds: 400), config()), "backlog, not an arrival")
        XCTAssertNil(job(reply(partlyHeard: true), config()), "already handed back to the user")
    }

    func test_alert_while_away_becomes_a_short_line() {
        let made = job(alert(), config(autoRead: false))
        XCTAssertEqual(made?.kind, .alert(idle: false))
        XCTAssertEqual(made?.passages, ["myna needs you, permission to run a command"])
        XCTAssertNil(made?.prefix)
        XCTAssertEqual(job(alert(type: "idle_prompt"), config())?.kind, .alert(idle: true))
    }

    func test_alert_at_desk_only_when_asked() {
        XCTAssertNil(job(alert(), config(), away: false))
        let desk = job(alert(), config(atDesk: true), away: false)
        XCTAssertEqual(desk?.requiresAway, false)
    }

    func test_alerts_off_ignores_alerts() {
        XCTAssertNil(job(alert(), config(alerts: false)))
    }

    // MARK: what the surfaces show

    func test_visible_pending_hides_alerts_until_alerts_are_on() throws {
        let suite = "dev.myna.tests.handsfree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = [reply(), alert()]
        XCTAssertEqual(HandsFreeSettings.visiblePending(items, defaults: defaults).map(\.id), ["u_1"])
        defaults.set(true, forKey: HandsFreeKey.speakAlerts)
        XCTAssertEqual(HandsFreeSettings.visiblePending(items, defaults: defaults).map(\.id), ["u_1", "a_1"])
    }

    func test_settings_load_defaults_and_overrides() throws {
        let suite = "dev.myna.tests.handsfree.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = HandsFreeSettings.load(from: defaults)
        XCTAssertFalse(fresh.autoReadWhenAway)
        XCTAssertFalse(fresh.speakAlerts)
        XCTAssertTrue(fresh.holdDuringCalls)
        XCTAssertEqual(fresh.away, AwayPolicy())
        defaults.set(7, forKey: HandsFreeKey.awayIdleMinutes)
        defaults.set(true, forKey: HandsFreeKey.awayWhenNotFrontmost)
        defaults.set(false, forKey: HandsFreeKey.awayWhenLocked)
        let changed = HandsFreeSettings.load(from: defaults)
        XCTAssertEqual(changed.away, AwayPolicy(whenLocked: false, whenIdle: true, idleMinutes: 7, whenNotFrontmost: true))
    }

    // MARK: hook status

    func test_hook_status_reads_claude_settings() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(ClaudeHookStatus.check(home: home), .noClaudeCode)

        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeHookStatus.check(home: home), .needsUpdate, "no settings.json")

        let settings = claude.appendingPathComponent("settings.json")
        let command = #""/v/python" "/h/.config/myna/hooks/myna-cc-announce.py""#
        let stopOnly = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
        try JSONSerialization.data(withJSONObject: stopOnly).write(to: settings)
        XCTAssertEqual(ClaudeHookStatus.check(home: home), .needsUpdate, "Stop only: the pre-update install")

        let both = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": command]]]],
            "Notification": [["matcher": "x", "hooks": [["command": "other"]]],
                             ["hooks": [["type": "command", "command": command]]]],
        ]]
        try JSONSerialization.data(withJSONObject: both).write(to: settings)
        XCTAssertEqual(ClaudeHookStatus.check(home: home), .installed)

        try Data("{ broken".utf8).write(to: settings)
        XCTAssertEqual(ClaudeHookStatus.check(home: home), .needsUpdate)
    }
}
