// FixtureLoader.swift — locates the shared test fixtures shipped from
// `docs/native-app/fixtures/`. xcodegen copies the folder into the test
// bundle as a folder reference (resource path: `fixtures/<name>.json`).
import Foundation
import XCTest

enum FixtureLoader {
    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: FixtureSentinel.self)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "json" : (name as NSString).pathExtension
        // Try bundle root first (xcodegen folder reference flattens).
        if let url = bundle.url(forResource: stem, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        // Then try inside a "fixtures" subdirectory.
        if let url = bundle.url(forResource: stem, withExtension: ext, subdirectory: "fixtures") {
            return try Data(contentsOf: url)
        }
        // Fall back to walking the repo from this source file (works when
        // tests run from xcodebuild but resources weren't copied for some
        // reason — useful during development).
        let here = URL(fileURLWithPath: String(describing: file))
        var dir = here.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate =
                dir
                .appendingPathComponent("docs/native-app/fixtures")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            dir.deleteLastPathComponent()
        }
        XCTFail("fixture \(name) not found in bundle or source tree", file: file, line: line)
        throw NSError(domain: "FixtureLoader", code: -1)
    }
}

/// Empty class just to give `Bundle(for:)` a target.
private final class FixtureSentinel {}
