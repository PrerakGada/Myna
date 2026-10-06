// BoldClaimsTests.swift — the "Read only the bold claims" extraction.
import XCTest

@testable import Myna

final class BoldClaimsTests: XCTestCase {

    func test_extracts_bold_claims_in_order_with_full_stops() {
        let reply = """
            I looked at the hook. **Filtering belongs in the app, not the hook.** The hook \
            is a copy. **The setting defaults off**, because keyword bold reads as fragments.
            """
        XCTAssertEqual(
            BoldClaims.extract(from: reply),
            ["Filtering belongs in the app, not the hook.", "The setting defaults off."]
        )
    }

    func test_no_bold_returns_nil_so_the_reply_is_read_in_full() {
        XCTAssertNil(BoldClaims.spokenText(from: "Plain reply with no emphasis at all."))
    }

    func test_bold_inside_code_is_ignored() {
        let reply = """
            ```python
            x = "**not a claim**"
            ```
            Use `**kwargs` here. **This is the claim.**
            """
        XCTAssertEqual(BoldClaims.extract(from: reply), ["This is the claim."])
    }

    func test_short_labels_are_dropped_but_long_colon_claims_kept() {
        let reply = "**Why:** because. **Next:** ship. **Three places need the same change:** a, b, c."
        XCTAssertEqual(BoldClaims.extract(from: reply), ["Three places need the same change."])
    }

    func test_inline_markup_and_links_are_spoken_as_plain_text() {
        let reply = "**Read [the plan](https://x.y) before *any* change**"
        XCTAssertEqual(BoldClaims.extract(from: reply), ["Read the plan before any change."])
    }

    func test_bold_does_not_span_lines() {
        XCTAssertEqual(BoldClaims.extract(from: "**open\nstill open** then **closed**"), ["closed."])
    }

    func test_registry_item_falls_back_to_full_reply() {
        let item = RegistryV2Item(
            id: "u1", source: "claude-code", projectId: "myna", title: "Done.",
            text: "Done. Nothing bold here.", announcedAtMs: 0, ttlS: 600)
        XCTAssertEqual(item.spokenText(boldClaimsOnly: true), "Done. Nothing bold here.")

        let bold = RegistryV2Item(
            id: "u2", source: "claude-code", projectId: "myna", title: "Done.",
            text: "Done. **It shipped.** Details.", announcedAtMs: 0, ttlS: 600)
        XCTAssertEqual(bold.spokenText(boldClaimsOnly: true), "It shipped.")
        XCTAssertEqual(bold.spokenText(boldClaimsOnly: false), "Done. **It shipped.** Details.")
    }
}
