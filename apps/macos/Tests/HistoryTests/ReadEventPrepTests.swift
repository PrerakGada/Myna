// ReadEventPrepTests.swift — the text prep a read was sent with, which the
// History pane needs to show it "as heard".
import XCTest

@testable import Myna

final class ReadEventPrepTests: XCTestCase {

    func test_records_from_before_text_prep_decode_with_no_prep() throws {
        let old = #"{"id":"a","started_at_ms":1,"title":"t","text":"x","source":"selection","voice":"af_heart"}"#
        let event = try JSONDecoder().decode(ReadEvent.self, from: Data(old.utf8))
        XCTAssertNil(event.prep)
    }

    func test_prep_round_trips() throws {
        let event = ReadEvent(title: "t", text: "**x**", source: .claudeCode, voice: "af_heart", prep: "auto")
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        XCTAssertEqual(json["prep"] as? String, "auto")
        XCTAssertEqual(try JSONDecoder().decode(ReadEvent.self, from: data).prep, "auto")
    }
}
