// Semver.swift — lightweight semver comparison for the What's New
// dialog (S10). We don't need a full semver implementation; we only
// need to answer:
//   - is `installed` strictly greater than `lastSeen`?
//   - is `installed` a minor-version bump from `lastSeen` (i.e. the
//     minor digit went up while major stayed equal)?
//
// Patch releases (0.x.y where y > 0) explicitly do NOT auto-show
// What's New, per S10 AC #8.
import Foundation

public struct Semver: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse a string of the form `MAJOR.MINOR.PATCH` (or `MAJOR.MINOR`
    /// — patch defaults to 0). Returns nil on anything else.
    public init?(_ string: String) {
        // Strip a leading "v" so `v0.2.0` and `0.2.0` both work.
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // Pre-release / build metadata (`0.2.0-rc1`, `0.2.0+build`) is
        // not supported — chop it off before parsing.
        if let dashIdx = trimmed.firstIndex(of: "-") {
            trimmed = String(trimmed[..<dashIdx])
        }
        if let plusIdx = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIdx])
        }
        let parts = trimmed.split(separator: ".").map { String($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let majorVal = Int(parts[0]), let minorVal = Int(parts[1]) else { return nil }
        let patchVal: Int
        if parts.count == 3 {
            guard let parsed = Int(parts[2]) else { return nil }
            patchVal = parsed
        } else {
            patchVal = 0
        }
        guard majorVal >= 0, minorVal >= 0, patchVal >= 0 else { return nil }
        self.major = majorVal
        self.minor = minorVal
        self.patch = patchVal
    }

    public static func < (lhs: Semver, rhs: Semver) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    /// True iff `self` is a minor bump (or major bump) over `other` —
    /// i.e. NOT a patch release. Used to gate auto-showing the dialog
    /// per S10 AC #8.
    public func isMinorOrMajorBumpOver(_ other: Semver) -> Bool {
        if major > other.major { return true }
        if major == other.major && minor > other.minor { return true }
        return false
    }

    public var displayString: String {
        "\(major).\(minor).\(patch)"
    }
}
