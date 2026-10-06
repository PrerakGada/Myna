// DashboardPaneTests.swift — navigation model + the deep-link route.
//
// DashboardPane is the single list of places the window can be; the
// sidebar, the popover's entry points and `myna://dashboard?pane=…` all
// read from it. These tests exist so adding a pane and forgetting to put
// it in a sidebar group fails here rather than by quietly disappearing
// from the UI.
import XCTest

@testable import Myna

@MainActor
final class DashboardPaneTests: XCTestCase {

    // MARK: - the model

    func testEveryPaneAppearsInExactlyOneSidebarGroup() {
        let grouped = DashboardPane.Group.allCases.flatMap(\.panes)
        XCTAssertEqual(
            Set(grouped), Set(DashboardPane.allCases),
            "a pane missing from every group is unreachable in the sidebar")
        XCTAssertEqual(grouped.count, DashboardPane.allCases.count, "a pane is listed twice")
    }

    func testEveryPaneHasATitleSubtitleAndSymbol() {
        for pane in DashboardPane.allCases {
            XCTAssertFalse(pane.title.isEmpty, "\(pane) has no title")
            XCTAssertFalse(pane.subtitle.isEmpty, "\(pane) has no subtitle")
            XCTAssertFalse(pane.systemImage.isEmpty, "\(pane) has no symbol")
        }
    }

    // MARK: - deep links

    func testParseAcceptsEveryPaneByItsOwnName() {
        for pane in DashboardPane.allCases {
            XCTAssertEqual(DashboardPane.parse(pane.rawValue), pane)
        }
    }

    func testParseIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(DashboardPane.parse("  HISTORY "), .history)
        XCTAssertEqual(DashboardPane.parse("Overview"), .overview)
    }

    func testParseUnderstandsTheObviousAliases() {
        XCTAssertEqual(DashboardPane.parse("stats"), .overview)
        XCTAssertEqual(DashboardPane.parse("analytics"), .overview)
        XCTAssertEqual(DashboardPane.parse("settings"), .shortcuts)
        XCTAssertEqual(DashboardPane.parse("recents"), .history)
        XCTAssertEqual(DashboardPane.parse("engine"), .daemon)
        XCTAssertEqual(DashboardPane.parse("privacy"), .account)
    }

    /// An unrecognised pane opens the window where it was rather than
    /// failing the URL — nothing here is privileged enough to be strict.
    func testParseReturnsNilForNothingAndNonsense() {
        XCTAssertNil(DashboardPane.parse(nil))
        XCTAssertNil(DashboardPane.parse(""))
        XCTAssertNil(DashboardPane.parse("   "))
        XCTAssertNil(DashboardPane.parse("telepathy"))
    }

    // MARK: - URL scheme

    func testDashboardURLParsesWithAndWithoutAPane() {
        XCTAssertEqual(
            URLSchemeHandler.parse(URL(string: "myna://dashboard")!),
            .openDashboard(pane: nil))
        XCTAssertEqual(
            URLSchemeHandler.parse(URL(string: "myna://dashboard?pane=history")!),
            .openDashboard(pane: .history))
        XCTAssertEqual(
            URLSchemeHandler.parse(URL(string: "myna://dashboard?pane=nonsense")!),
            .openDashboard(pane: nil))
    }

    /// The route must not have widened the scheme's surface: everything
    /// that was refused before is still refused.
    func testUnknownRoutesAreStillDropped() {
        XCTAssertNil(URLSchemeHandler.parse(URL(string: "myna://speak?text=hello")!))
        XCTAssertNil(URLSchemeHandler.parse(URL(string: "myna://dashboards")!))
        XCTAssertNil(URLSchemeHandler.parse(URL(string: "https://dashboard")!))
    }
}
