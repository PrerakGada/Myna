// StudioCleanupTests.swift — the text rules Studio applies before a
// document is rendered. Each optional rule has a "doesn't over-clean" case
// next to the case it exists for.
import XCTest

@testable import Myna

final class StudioCleanupTests: XCTestCase {

    // MARK: - always-on

    func test_normalize_collapses_spacing_and_strips_invisibles() {
        let raw = "One\u{00A0}\u{00A0}two\u{200B}\r\n\r\n\r\n\r\nthree\u{FEFF}   four\t\tfive  \n"
        XCTAssertEqual(TextCleanup.normalize(raw), "One two\n\nthree four five")
    }

    func test_normalize_replaces_ligatures_and_joins_soft_hyphen_breaks() {
        XCTAssertEqual(TextCleanup.normalize("the ﬁrst ﬂoor"), "the first floor")
        XCTAssertEqual(TextCleanup.normalize("exam\u{00AD}\nple"), "example")
    }

    func test_hyphenated_line_break_is_joined_only_before_lower_case() {
        XCTAssertEqual(TextCleanup.joinHyphenatedLineBreaks("an exam-\nple of it"), "an example of it")
        XCTAssertEqual(TextCleanup.joinHyphenatedLineBreaks("Jean-\nPaul Sartre"), "Jean-\nPaul Sartre")
        XCTAssertEqual(TextCleanup.joinHyphenatedLineBreaks("a list -\nthen more"), "a list -\nthen more")
    }

    func test_unwrap_joins_wrapped_lines_and_keeps_short_line_breaks() {
        // A short line ends a paragraph: the break after it is kept, while
        // lines that reached the width are joined.
        let text = """
        This line is long enough that it was clearly broken at the page width
        and it continues here on the following line of the same paragraph.
        Short end.
        Next paragraph without a blank line, which PDFs often produce here ok
        and its second line.

        After a blank line.
        """
        XCTAssertEqual(TextCleanup.unwrap(text), """
        This line is long enough that it was clearly broken at the page width \
        and it continues here on the following line of the same paragraph. Short end.
        Next paragraph without a blank line, which PDFs often produce here ok \
        and its second line.

        After a blank line.
        """)
    }

    func test_unwrap_keeps_list_items_on_their_own_lines() {
        let text = """
        The ingredients for this recipe are listed below in order of use:
        • flour, sifted twice through a fine sieve before measuring it out
        • butter
        """
        XCTAssertTrue(TextCleanup.unwrap(text, width: 70).contains("\n• flour"))
    }

    func test_looks_hard_wrapped_detects_fixed_width_prose_but_not_verse() {
        let prose = (0..<14).map { index in
            index % 5 == 4 ? "Short line." : "This is a hard wrapped line of prose from an old text file, ok"
        }.joined(separator: "\n")
        XCTAssertTrue(TextCleanup.looksHardWrapped(prose))

        let verse = """
        Tyger Tyger, burning bright,
        In the forests of the night;
        What immortal hand or eye,
        Could frame thy fearful symmetry?
        In what distant deeps or skies.
        Burnt the fire of thine eyes?
        On what wings dare he aspire?
        What the hand, dare seize the fire?
        And what shoulder, & what art,
        Could twist the sinews of thy heart?
        And when thy heart began to beat,
        What dread hand? & what dread feet?
        """
        XCTAssertFalse(TextCleanup.looksHardWrapped(verse))

        let oneLinePerParagraph = (0..<12).map { _ in
            String(repeating: "A long paragraph written on one line. ", count: 8)
        }.joined(separator: "\n")
        XCTAssertFalse(TextCleanup.looksHardWrapped(oneLinePerParagraph))
    }

    // MARK: - optional: URLs

    func test_remove_urls_keeps_sentence_punctuation() {
        XCTAssertEqual(
            TextCleanup.removeURLs("See https://example.com/a/b?c=1. Then continue."),
            "See. Then continue.")
        XCTAssertEqual(
            TextCleanup.removeURLs("Docs (https://docs.example.org/x) are here, and www.example.com too."),
            "Docs are here, and too.")
        XCTAssertEqual(TextCleanup.removeURLs("A link <https://x.io/y> inline."), "A link inline.")
    }

    func test_remove_urls_leaves_bare_domains_and_emails() {
        let text = "We use example.com as a name. Mail me@example.com."
        XCTAssertEqual(TextCleanup.removeURLs(text), text)
    }

    // MARK: - optional: citations

    func test_remove_citations_strips_numeric_and_wikipedia_markers() {
        XCTAssertEqual(
            TextCleanup.removeCitationMarkers("Water boils at 100 °C.[1] It is wet [2, 3] and clear [4–6].[citation needed]"),
            "Water boils at 100 °C. It is wet and clear.")
        XCTAssertEqual(TextCleanup.removeCitationMarkers("As noted[a], it works."), "As noted, it works.")
    }

    func test_remove_citations_keeps_bracketed_words_and_years() {
        let text = "He said [sic] it was built in [1996] and [Section 4] explains why."
        XCTAssertEqual(TextCleanup.removeCitationMarkers(text), text)
    }

    // MARK: - optional: short sections

    func test_front_matter_matches_whole_titles_only() {
        XCTAssertTrue(CleanupOptions.looksLikeFrontMatter(title: "Table of Contents"))
        XCTAssertTrue(CleanupOptions.looksLikeFrontMatter(title: "COPYRIGHT"))
        XCTAssertTrue(CleanupOptions.looksLikeFrontMatter(title: "Also by Jane Doe"))
        XCTAssertFalse(CleanupOptions.looksLikeFrontMatter(title: "Contents of the Heart"))
        XCTAssertFalse(CleanupOptions.looksLikeFrontMatter(title: "Chapter 1: Cover Story"))
    }

    func test_is_skippable_by_length_or_title() {
        XCTAssertTrue(CleanupOptions.isSkippable(title: "Dedication", words: 12))
        XCTAssertTrue(CleanupOptions.isSkippable(title: "Contents", words: 400))
        XCTAssertFalse(CleanupOptions.isSkippable(title: "Chapter 1", words: 2_000))
    }

    func test_defaults_depend_on_source() {
        XCTAssertFalse(CleanupOptions.defaults(for: .pasted, sectionCount: 1).removeCitations)
        XCTAssertTrue(CleanupOptions.defaults(for: .web, sectionCount: 1).removeCitations)
        XCTAssertTrue(CleanupOptions.defaults(for: .pdf, sectionCount: 1).removeURLs)
        XCTAssertFalse(CleanupOptions.defaults(for: .epub, sectionCount: 2).skipShortSections)
        XCTAssertTrue(CleanupOptions.defaults(for: .epub, sectionCount: 12).skipShortSections)
    }

    // MARK: - text helpers

    func test_word_count_and_spoken_heading() {
        XCTAssertEqual(StudioText.wordCount("  one two\n\nthree\tfour "), 4)
        XCTAssertEqual(StudioText.wordCount(""), 0)
        XCTAssertEqual(StudioText.spokenHeading("Chapter 1"), "Chapter 1.")
        XCTAssertEqual(StudioText.spokenHeading("Why now?"), "Why now?")
    }
}
