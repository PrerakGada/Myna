// ReadingEventsTests.swift — the daemon's /reading/events feed, applied to
// the read it describes (ReadingFeed's pure half).
import XCTest

@testable import Myna

final class ReadingEventsTests: XCTestCase {
    private func apply(_ event: String, _ json: String, to current: DaemonReading?) -> DaemonReading? {
        ReadingEvents.apply(event: event, data: Data(json.utf8), to: current)
    }

    func testARead_startsPlaysPausesAndEnds() {
        var r = apply("start", #"{"id":"r-1","text":"x","spoken":"Hello there."}"#, to: nil)
        XCTAssertEqual(r, DaemonReading(id: "r-1", spoken: "Hello there.", state: .preparing))
        r = apply("chunk", #"{"id":"r-1","index":0,"words":[]}"#, to: r)
        XCTAssertEqual(r?.state, .playing)
        r = apply("word", #"{"id":"r-1","i":1,"at":[6,11],"src":null}"#, to: r)
        XCTAssertEqual(r?.word, NSRange(location: 6, length: 5))
        r = apply("pause", #"{"id":"r-1","position_ms":900}"#, to: r)
        XCTAssertEqual(r?.state, .paused)
        r = apply("resume", #"{"id":"r-1","position_ms":900}"#, to: r)
        XCTAssertEqual(r?.state, .playing)
        XCTAssertEqual(r?.word, NSRange(location: 6, length: 5))
        XCTAssertNil(apply("end", #"{"id":"r-1","reason":"finished"}"#, to: r))
    }

    func testEventsForAnotherReadAreIgnored() {
        let r = DaemonReading(id: "r-1", spoken: "Hi.", state: .playing)
        XCTAssertEqual(apply("end", #"{"id":"r-0","reason":"replaced"}"#, to: r), r)
        XCTAssertEqual(apply("word", #"{"id":"r-0","at":[0,2]}"#, to: r), r)
        XCTAssertEqual(apply("word", "{oops", to: r), r)
    }

    func testASnapshotSetsOrClearsTheRead() {
        let r = DaemonReading(id: "r-1", spoken: "Hi.", state: .playing)
        XCTAssertNil(apply("snapshot", #"{"reading":null}"#, to: r))
        XCTAssertNil(apply("snapshot", #"{"reading":{"id":"r-1","spoken":"Hi.","state":"ended"}}"#, to: r))
        let joined = apply(
            "snapshot",
            #"{"reading":{"id":"r-2","spoken":"Hello there.","state":"paused","word":{"i":0,"at":[0,5]}}}"#,
            to: nil)
        XCTAssertEqual(joined, DaemonReading(
            id: "r-2", spoken: "Hello there.", state: .paused, word: NSRange(location: 0, length: 5)))
    }
}
