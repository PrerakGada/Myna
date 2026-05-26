// swift-tools-version: 5.9
//
// MynaKaraoke — floating karaoke ribbon sidecar (Track C of v0.2).
//
// Layout choice: library target (MynaKaraokeCore) + thin executable
// (MynaKaraoke). The library holds all logic that XCTest needs to import;
// the executable is purely AppDelegate bootstrap. This is the standard
// SwiftPM pattern for AppKit apps that want testable code.
//
// arm64-only — mlx-audio (Track B) is Apple Silicon only.
// macOS 14 (Sonoma) minimum — unlocks TextKit2 and skips back-compat ladder.

import PackageDescription

let package = Package(
    name: "MynaKaraoke",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MynaKaraoke",
            dependencies: ["MynaKaraokeCore"],
            path: "Sources/MynaKaraoke"
        ),
        .target(
            name: "MynaKaraokeCore",
            path: "Sources/MynaKaraokeCore"
        ),
        .testTarget(
            name: "MynaKaraokeTests",
            dependencies: ["MynaKaraokeCore"],
            path: "Tests/MynaKaraokeTests"
        )
    ]
)
