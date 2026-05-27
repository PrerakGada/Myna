// SemverTests.swift — exercise the small semver helper used by the
// What's New dialog gating (S10).
import XCTest

@testable import Myna

final class SemverTests: XCTestCase {

    func test_parse_three_part() {
        let v = Semver("0.2.1")
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 1)
    }

    func test_parse_two_part_defaults_patch_to_zero() {
        let v = Semver("0.2")
        XCTAssertEqual(v?.major, 0)
        XCTAssertEqual(v?.minor, 2)
        XCTAssertEqual(v?.patch, 0)
    }

    func test_parse_with_v_prefix() {
        XCTAssertEqual(Semver("v0.2.0"), Semver("0.2.0"))
        XCTAssertEqual(Semver("V0.2.0"), Semver("0.2.0"))
    }

    func test_parse_strips_prerelease_and_build() {
        XCTAssertEqual(Semver("0.2.0-rc1"), Semver("0.2.0"))
        XCTAssertEqual(Semver("0.2.0+build42"), Semver("0.2.0"))
    }

    func test_invalid_strings_fail() {
        XCTAssertNil(Semver(""))
        XCTAssertNil(Semver("garbage"))
        XCTAssertNil(Semver("0"))
        XCTAssertNil(Semver("0.x.0"))
        XCTAssertNil(Semver("-1.0.0"))
    }

    func test_comparable_ordering() {
        XCTAssertTrue(Semver("0.1.0")! < Semver("0.2.0")!)
        XCTAssertTrue(Semver("0.2.0")! < Semver("0.2.1")!)
        XCTAssertTrue(Semver("0.2.0")! < Semver("1.0.0")!)
        XCTAssertFalse(Semver("0.2.0")! < Semver("0.2.0")!)
    }

    func test_isMinorOrMajorBumpOver_true_for_minor_bump() {
        let new = Semver("0.2.0")!
        let old = Semver("0.1.5")!
        XCTAssertTrue(new.isMinorOrMajorBumpOver(old))
    }

    func test_isMinorOrMajorBumpOver_false_for_patch_bump() {
        let new = Semver("0.2.1")!
        let old = Semver("0.2.0")!
        XCTAssertFalse(new.isMinorOrMajorBumpOver(old), "patch bump should NOT trigger What's New")
    }

    func test_isMinorOrMajorBumpOver_true_for_major_bump() {
        XCTAssertTrue(Semver("1.0.0")!.isMinorOrMajorBumpOver(Semver("0.99.0")!))
    }

    func test_display_string_round_trips() {
        XCTAssertEqual(Semver("0.2.1")?.displayString, "0.2.1")
    }
}
