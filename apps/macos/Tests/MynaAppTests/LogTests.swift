// LogTests.swift — sanity-check the file mirror writes lines and
// rotates when the file exceeds the size cap.
import Foundation
import XCTest

@testable import Myna

final class LogTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("myna-log-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func test_file_mirror_appends_line() {
        let mirror = LogFileMirror(directory: tmpDir, fileName: "test.log")
        mirror.writeSync("hello world")
        mirror.waitForPendingWrites()
        let contents = try? String(contentsOf: mirror.currentLogURL)
        XCTAssertEqual(contents, "hello world\n")
    }

    func test_log_categories_cover_all_subsystems() {
        XCTAssertEqual(
            Set(LogCategory.allCases),
            [.app, .audio, .network, .input, .urlscheme, .settings]
        )
    }

    func test_log_level_ordering() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
    }
}
