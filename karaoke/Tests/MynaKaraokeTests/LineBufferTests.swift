// LineBufferTests.swift — NDJSON line accumulation.

import XCTest
@testable import MynaKaraokeCore

final class LineBufferTests: XCTestCase {

    func test_emptyInput_emitsNothing() {
        let buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data()).count, 0)
        XCTAssertEqual(buffer.pendingBytes, 0)
    }

    func test_singleCompleteLine_emitsOne() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("hello\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "hello")
        XCTAssertEqual(buffer.pendingBytes, 0)
    }

    func test_partialLine_buffersUntilNewline() {
        let buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("hel".utf8)).count, 0)
        XCTAssertEqual(buffer.append(Data("lo".utf8)).count, 0)
        let lines = buffer.append(Data("\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "hello")
    }

    func test_multipleLinesInOneChunk_emitsAllInOrder() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("first\nsecond\nthird\n".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) },
                       ["first", "second", "third"])
    }

    func test_trailingPartial_isHeldUntilNewlineArrives() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("first\nsec".utf8))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["first"])
        XCTAssertEqual(buffer.pendingBytes, 3) // "sec"
        let more = buffer.append(Data("ond\n".utf8))
        XCTAssertEqual(more.map { String(data: $0, encoding: .utf8) }, ["second"])
    }

    func test_oversizedPartial_isDroppedDefensively() {
        let buffer = LineBuffer(maxLineBytes: 16)
        let huge = Data(repeating: 0x41, count: 64)  // 'A' × 64, no newline
        let lines = buffer.append(huge)
        XCTAssertEqual(lines.count, 0)
        XCTAssertEqual(buffer.pendingBytes, 0, "overlong partial should drop")
    }
}
