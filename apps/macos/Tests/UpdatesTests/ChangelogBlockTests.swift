// ChangelogBlockTests.swift — What's New lays out headings, paragraphs and
// bullets itself, since SwiftUI's markdown parsing is inline-only.
import XCTest

@testable import Myna

final class ChangelogBlockTests: XCTestCase {

    func test_splits_headings_paragraphs_and_bullets() {
        let markdown = """
        ## What's new in Myna 0.5

        ### One download
        Myna now installs from a single
        disk image.

        - First bullet that wraps
          onto a second line.
        - Second bullet.
        """
        XCTAssertEqual(ChangelogBlock.parse(markdown), [
            .heading("What's new in Myna 0.5", level: 2),
            .heading("One download", level: 3),
            .paragraph("Myna now installs from a single disk image."),
            .bullet("First bullet that wraps onto a second line."),
            .bullet("Second bullet."),
        ])
    }

    func test_a_paragraph_after_a_list_starts_a_new_block() {
        let markdown = """
        - A bullet.
        A paragraph straight after it.
        """
        XCTAssertEqual(ChangelogBlock.parse(markdown), [
            .bullet("A bullet."),
            .paragraph("A paragraph straight after it."),
        ])
    }
}
