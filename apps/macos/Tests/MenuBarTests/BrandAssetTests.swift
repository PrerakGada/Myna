import AppKit
import SwiftUI
import XCTest

@testable import Myna

final class BrandAssetTests: XCTestCase {
    @MainActor
    func testNativeMenuStatesRenderAtRetinaSize() throws {
        for state in [IconState.idle, .speaking, .thinking, .paused, .error] {
            let renderer = ImageRenderer(content:
                BirdIconView(state: state, suppressAnimation: true)
                    .foregroundStyle(.black)
                    .environment(\.colorScheme, .light)
            )
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 40)
            XCTAssertEqual(image.height, 36)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("myna-native-\(state.rawValue).png"))
        }
    }
    func testCompiledBrandImagesLoad() throws {
        for name in [BirdIcon.outlineName, BirdIcon.filledName, BirdIcon.artworkName] {
            let image = try XCTUnwrap(NSImage(named: name), "Missing compiled asset: \(name)")
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    func testTemplateAssetsRetainTransparencyAndDifferentInkCoverage() throws {
        func coverage(_ name: String) throws -> Double {
            let image = try XCTUnwrap(NSImage(named: name))
            XCTAssertTrue(image.isTemplate, "\(name) must follow the system foreground colour")
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cg)
            XCTAssertTrue(bitmap.hasAlpha)
            XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
            var sum = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    sum += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            return sum / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
        }
        let outline = try coverage(BirdIcon.outlineName)
        let filled = try coverage(BirdIcon.filledName)
        XCTAssertGreaterThan(outline, 0.05)
        XCTAssertGreaterThan(filled, outline * 1.3)
    }
}
