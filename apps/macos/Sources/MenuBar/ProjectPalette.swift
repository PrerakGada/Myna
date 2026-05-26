// ProjectPalette.swift — deterministic project-id → hue mapping used by
// CC-ready toasts (S08) and the Claude Code submenu (S06).
//
// Per Caravaggio's 04-visual-direction.md § 2: 10-hue palette,
// colorblind-safe, FNV-1a hash → palette index. The determinism IS the
// feature — same project_id always maps to the same hue, so users build
// muscle memory.
//
// Hex values must match the doc exactly. Tests assert this so accidental
// drift fails CI.
import SwiftUI

public enum ProjectPalette {
    /// Named entry in the palette. `index` is the slot 0..<10 (mod target);
    /// `name` and `hex` come straight from Caravaggio's table.
    public struct Color: Sendable, Equatable {
        public let index: Int
        public let name: String
        public let hex: String

        /// Decode the hex into an sRGB triple in 0..<1. Convenience for
        /// SwiftUI Color construction.
        public var rgb: RGB {
            ProjectPalette.parseHex(hex)
        }
    }

    /// sRGB color triple, 0..<1 per component.
    public struct RGB: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The 10 palette entries, in declaration order. Index 0 = Coral.
    public static let entries: [Color] = [
        Color(index: 0, name: "Coral", hex: "#FF6B6B"),
        Color(index: 1, name: "Marigold", hex: "#F2A93B"),
        Color(index: 2, name: "Olive", hex: "#A8B545"),
        Color(index: 3, name: "Emerald", hex: "#3FB46C"),
        Color(index: 4, name: "Teal", hex: "#2BB4B0"),
        Color(index: 5, name: "Sky", hex: "#4DA6FF"),
        Color(index: 6, name: "Iris", hex: "#7B5BFF"),
        Color(index: 7, name: "Orchid", hex: "#C964D4"),
        Color(index: 8, name: "Rose", hex: "#FF7AA8"),
        Color(index: 9, name: "Slate", hex: "#9098A6"),
    ]

    /// Map a project identifier (typically the absolute repo root path,
    /// but any stable string works) to a deterministic palette entry.
    ///
    /// Algorithm: FNV-1a (32-bit) on the UTF-8 bytes, modulo 10.
    public static func color(for projectId: String) -> Color {
        let idx = Int(fnv1a32(projectId) % UInt32(entries.count))
        return entries[idx]
    }

    /// FNV-1a 32-bit hash. Exposed for tests.
    public static func fnv1a32(_ input: String) -> UInt32 {
        let offsetBasis: UInt32 = 0x811c_9dc5
        let prime: UInt32 = 0x0100_0193
        var hash: UInt32 = offsetBasis
        for byte in input.utf8 {
            hash ^= UInt32(byte)
            hash &*= prime
        }
        return hash
    }

    /// Parse `#RRGGBB` into 0..<1 sRGB components. Returns black on
    /// malformed input — palette hexes are validated by unit test, so this
    /// only kicks in if a future edit corrupts the table.
    public static func parseHex(_ hex: String) -> RGB {
        var raw = hex
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else {
            return RGB(red: 0, green: 0, blue: 0)
        }
        let red = Double((value >> 16) & 0xff) / 255.0
        let green = Double((value >> 8) & 0xff) / 255.0
        let blue = Double(value & 0xff) / 255.0
        return RGB(red: red, green: green, blue: blue)
    }
}

extension Color {
    /// Construct a SwiftUI Color from a ProjectPalette entry.
    public init(palette entry: ProjectPalette.Color) {
        let triple = entry.rgb
        self.init(.sRGB, red: triple.red, green: triple.green, blue: triple.blue, opacity: 1.0)
    }
}
