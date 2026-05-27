// PopoverModelTests.swift — verify state→view mapping for the
// redesigned menu bar popover (S06). Tests build the model directly
// without SwiftUI, asserting the structure matches Sally's spec.
//
// swiftlint:disable force_unwrapping
import XCTest

@testable import Myna

final class PopoverModelTests: XCTestCase {

    private func build(
        playerState: AudioPlayer.State,
        nowReading: PopoverModel.NowReading? = nil,
        recents: [RecentItem] = [],
        ccItems: [RegistryV2Item] = [],
        reachability: MenuBarController.DaemonReachability = .up,
        hotkeyLabel: String? = "⌘⌥⇧S"
    ) -> PopoverModel {
        PopoverModelBuilder.build(
            playerState: playerState,
            nowReading: nowReading,
            recents: recents,
            ccItems: ccItems,
            reachability: reachability,
            hotkeyLabelFor: { _ in hotkeyLabel }
        )
    }

    // MARK: - status section

    func test_idle_status_when_player_idle() {
        let model = build(playerState: .idle)
        XCTAssertTrue(model.status.isIdle)
        XCTAssertNil(model.status.nowReading)
    }

    func test_playing_status_has_now_reading() {
        let nr = PopoverModel.NowReading(
            title: "Test", voice: "Bella", speed: 1.0, positionSeconds: 0, durationSeconds: 10
        )
        let model = build(playerState: .playing, nowReading: nr)
        if case .playing(let captured) = model.status {
            XCTAssertEqual(captured.title, "Test")
            XCTAssertEqual(captured.voice, "Bella")
        } else {
            XCTFail("expected .playing status")
        }
    }

    func test_paused_status_when_player_paused() {
        let nr = PopoverModel.NowReading(
            title: "X", voice: "Y", speed: 1.0, positionSeconds: 5, durationSeconds: 20
        )
        let model = build(playerState: .paused, nowReading: nr)
        if case .paused = model.status {
            XCTAssertEqual(model.status.nowReading?.title, "X")
        } else {
            XCTFail("expected .paused")
        }
    }

    func test_daemon_down_overrides_to_error() {
        let model = build(playerState: .idle, reachability: .down)
        if case .error = model.status {
            // expected
        } else {
            XCTFail("expected .error when reachability is .down")
        }
    }

    // MARK: - loading status (pre-audio)

    func test_idle_with_loading_flag_yields_loading_status() {
        let model = PopoverModelBuilder.build(
            playerState: .idle,
            nowReading: nil,
            recents: [],
            ccItems: [],
            reachability: .up,
            hotkeyLabelFor: { _ in nil },
            isPlayerLoading: true,
            loadingTitle: "hello.com"
        )
        if case .loading(let title) = model.status {
            XCTAssertEqual(title, "hello.com")
        } else {
            XCTFail("expected .loading status")
        }
    }

    func test_loading_status_clears_when_player_starts_playing() {
        let nr = PopoverModel.NowReading(
            title: "T", voice: "V", speed: 1.0, positionSeconds: 0, durationSeconds: 1
        )
        // Even with isPlayerLoading=true, .playing wins because the
        // player has moved past the prelude.
        let model = PopoverModelBuilder.build(
            playerState: .playing,
            nowReading: nr,
            recents: [],
            ccItems: [],
            reachability: .up,
            hotkeyLabelFor: { _ in nil },
            isPlayerLoading: true,
            loadingTitle: "x"
        )
        if case .playing = model.status {
            // ok
        } else {
            XCTFail("expected .playing to dominate over isPlayerLoading")
        }
    }

    func test_loading_status_nil_title_is_acceptable() {
        let model = PopoverModelBuilder.build(
            playerState: .idle,
            nowReading: nil,
            recents: [],
            ccItems: [],
            reachability: .up,
            hotkeyLabelFor: { _ in nil },
            isPlayerLoading: true,
            loadingTitle: nil
        )
        if case .loading(let title) = model.status {
            XCTAssertNil(title)
        } else {
            XCTFail("expected .loading with nil title")
        }
    }

    func test_daemon_down_overrides_loading_to_error() {
        let model = PopoverModelBuilder.build(
            playerState: .idle,
            nowReading: nil,
            recents: [],
            ccItems: [],
            reachability: .down,
            hotkeyLabelFor: { _ in nil },
            isPlayerLoading: true,
            loadingTitle: "x"
        )
        if case .error = model.status {
            // ok
        } else {
            XCTFail("daemon-down must dominate over loading")
        }
    }

    // MARK: - transport rows

    func test_transport_rows_include_pause_stop_skips() {
        let model = build(playerState: .playing, nowReading: nil)
        let ids = model.transport.map(\.id)
        XCTAssertEqual(ids, [.pause, .stop, .skipForward, .skipBack])
    }

    func test_transport_pause_label_says_resume_when_paused() {
        let nr = PopoverModel.NowReading(title: "x", voice: "y", speed: 1.0, positionSeconds: 0, durationSeconds: 1)
        let model = build(playerState: .paused, nowReading: nr)
        let pauseRow = model.transport.first { $0.id == .pause }!
        XCTAssertEqual(pauseRow.title, "Resume")
    }

    func test_transport_rows_disabled_when_idle() {
        let model = build(playerState: .idle)
        for row in model.transport {
            XCTAssertFalse(row.isEnabled, "row \(row.id) should be disabled at idle")
        }
    }

    func test_transport_pause_row_carries_hotkey_label() {
        let model = build(playerState: .playing, hotkeyLabel: "⌘⌥⇧S")
        let pauseRow = model.transport.first { $0.id == .pause }!
        XCTAssertEqual(pauseRow.hotkeyLabel, "⌘⌥⇧S")
    }

    func test_transport_hotkey_label_nil_when_unbound() {
        let model = build(playerState: .playing, hotkeyLabel: nil)
        let pauseRow = model.transport.first { $0.id == .pause }!
        XCTAssertNil(pauseRow.hotkeyLabel)
    }

    // MARK: - Claude Code submenu visibility

    func test_cc_submenu_hidden_when_empty() {
        let model = build(playerState: .idle, ccItems: [])
        XCTAssertFalse(model.showClaudeCodeSubmenu)
    }

    func test_cc_submenu_shown_when_non_empty() {
        let item = RegistryV2Item(
            id: "i1", source: "claude-code", projectId: "p", title: "t", announcedAtMs: 0, ttlS: 600
        )
        let model = build(playerState: .idle, ccItems: [item])
        XCTAssertTrue(model.showClaudeCodeSubmenu)
    }

    // MARK: - now reading formatting

    func test_truncated_title_appends_ellipsis() {
        let long = String(repeating: "a", count: 100)
        let nr = PopoverModel.NowReading(title: long, voice: "v", speed: 1.0, positionSeconds: 0, durationSeconds: 0)
        XCTAssertEqual(nr.truncatedTitle.count, 39)  // 38 chars + ellipsis (1 char)
        XCTAssertTrue(nr.truncatedTitle.hasSuffix("…"))
    }

    func test_short_title_not_truncated() {
        let nr = PopoverModel.NowReading(title: "short", voice: "v", speed: 1.0, positionSeconds: 0, durationSeconds: 0)
        XCTAssertEqual(nr.truncatedTitle, "short")
    }

    func test_metadata_string_format() {
        let nr = PopoverModel.NowReading(
            title: "x", voice: "Bella", speed: 1.2, positionSeconds: 42, durationSeconds: 198
        )
        XCTAssertEqual(nr.formattedMetadata, "Bella · 1.2x · 0:42 / 3:18")
    }
}

// swiftlint:enable force_unwrapping
