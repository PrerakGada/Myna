// ProtocolTests.swift — Codable roundtrip + discriminator decode.

import XCTest
@testable import MynaKaraokeCore

final class ProtocolTests: XCTestCase {

    // MARK: - Roundtrip

    func test_startMessage_roundtrips() throws {
        let original = StartMessage(
            id: "u_2c1f",
            sentence: "Hello world, this is Myna.",
            words: [
                .init(i: 0, t: "Hello"),
                .init(i: 1, t: "world,"),
                .init(i: 2, t: "this"),
                .init(i: 3, t: "is"),
                .init(i: 4, t: "Myna.")
            ],
            estimatedDurationMs: 2400,
            voice: "af_heart"
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(StartMessage.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_wordMessage_roundtrips() throws {
        let original = WordMessage(id: "u_2c1f", i: 2, tMs: 1100)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(WordMessage.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_pauseMessage_roundtrips() throws {
        let original = PauseMessage(id: "u_2c1f")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(PauseMessage.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_resumeMessage_roundtrips() throws {
        let original = ResumeMessage(id: "u_2c1f", tMs: 1100)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ResumeMessage.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_stopMessage_roundtrips() throws {
        let original = StopMessage(id: "u_2c1f")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(StopMessage.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_configMessage_roundtrips() throws {
        let original = ConfigMessage(
            fontSize: 22, position: "bottom", theme: "dark", opacity: 0.95
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ConfigMessage.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_helloAndAck_roundtrip() throws {
        let hello = HelloMessage(sidecarPid: 54321)
        let helloData = try JSONEncoder().encode(hello)
        XCTAssertEqual(try JSONDecoder().decode(HelloMessage.self, from: helloData), hello)

        let ack = AckMessage(id: "u_2c1f")
        let ackData = try JSONEncoder().encode(ack)
        XCTAssertEqual(try JSONDecoder().decode(AckMessage.self, from: ackData), ack)
    }

    // MARK: - Wire-format conformance

    func test_startMessage_matchesWireFormat() throws {
        // The exact bytes Track B writes — taken from
        // docs/v0.2-plan/02-karaoke-architecture.md § 2.
        let parts = [
            #"{"v":1,"type":"start","id":"u_2c1f","#,
            #""sentence":"Hello world, this is Myna.","#,
            #""words":[{"i":0,"t":"Hello"},{"i":1,"t":"world,"},"#,
            #"{"i":2,"t":"this"},{"i":3,"t":"is"},{"i":4,"t":"Myna."}],"#,
            #""estimatedDurationMs":2400,"voice":"af_heart"}"#
        ]
        let wire = parts.joined()
        let decoded = try JSONDecoder().decode(StartMessage.self, from: Data(wire.utf8))
        XCTAssertEqual(decoded.id, "u_2c1f")
        XCTAssertEqual(decoded.words.count, 5)
        XCTAssertEqual(decoded.words[2].t, "this")
        XCTAssertEqual(decoded.estimatedDurationMs, 2400)
        XCTAssertEqual(decoded.voice, "af_heart")
    }

    // MARK: - Discriminator

    func test_discriminator_routesToStart() throws {
        let parts = [
            #"{"v":1,"type":"start","id":"u","sentence":"hi","#,
            #""words":[{"i":0,"t":"hi"}],"#,
            #""estimatedDurationMs":100,"voice":"af_heart"}"#
        ]
        let line = Data(parts.joined().utf8)
        let parsed = try IncomingMessage.decode(line: line)
        guard case .start(let start) = parsed else {
            XCTFail("expected .start, got \(String(describing: parsed))"); return
        }
        XCTAssertEqual(start.id, "u")
    }

    func test_discriminator_routesToWord() throws {
        let line = Data(#"{"v":1,"type":"word","id":"u","i":2,"tMs":1100}"#.utf8)
        let parsed = try IncomingMessage.decode(line: line)
        guard case .word(let word) = parsed else {
            XCTFail("expected .word"); return
        }
        XCTAssertEqual(word.i, 2)
        XCTAssertEqual(word.tMs, 1100)
    }

    func test_discriminator_returnsUnknownForFutureType() throws {
        let line = Data(#"{"v":2,"type":"some-future-thing","x":42}"#.utf8)
        let parsed = try IncomingMessage.decode(line: line)
        guard case .unknown(let type, let v) = parsed else {
            XCTFail("expected .unknown, got \(String(describing: parsed))"); return
        }
        XCTAssertEqual(type, "some-future-thing")
        XCTAssertEqual(v, 2)
    }

    /// Even known type names must be rejected when v != 1. A future
    /// protocol revision may keep the `type` discriminator but change
    /// the field layout — decoding such a payload against the v1 struct
    /// would silently mis-interpret data. The decoder gates on v first.
    func test_discriminator_rejectsKnownTypeWithWrongVersion() throws {
        // v=2 with a "start"-shaped payload. The v1 struct could decode
        // this just fine, but the version gate must short-circuit to
        // .unknown before the type switch is reached.
        let parts = [
            #"{"v":2,"type":"start","id":"u","sentence":"hi","#,
            #""words":[{"i":0,"t":"hi"}],"#,
            #""estimatedDurationMs":100,"voice":"af_heart"}"#
        ]
        let line = Data(parts.joined().utf8)
        let parsed = try IncomingMessage.decode(line: line)
        guard case .unknown(let type, let v) = parsed else {
            XCTFail("expected .unknown for v=2 start, got \(String(describing: parsed))"); return
        }
        XCTAssertEqual(type, "start")
        XCTAssertEqual(v, 2)
    }

    /// v=0 (missing or explicitly zero) also routes to .unknown.
    func test_discriminator_rejectsMissingVersion() throws {
        let line = Data(#"{"type":"word","id":"u","i":2,"tMs":1100}"#.utf8)
        let parsed = try IncomingMessage.decode(line: line)
        guard case .unknown(let type, let v) = parsed else {
            XCTFail("expected .unknown when v is missing, got \(String(describing: parsed))"); return
        }
        XCTAssertEqual(type, "word")
        XCTAssertEqual(v, 0)
    }

    func test_discriminator_blanksReturnNil() throws {
        XCTAssertNil(try IncomingMessage.decode(line: Data()))
        XCTAssertNil(try IncomingMessage.decode(line: Data("   \t  \r\n".utf8)))
    }

    func test_discriminator_throwsOnMalformedJSON() {
        let line = Data("not json".utf8)
        XCTAssertThrowsError(try IncomingMessage.decode(line: line))
    }

    func test_discriminator_throwsOnNonObject() {
        let line = Data("[1, 2, 3]".utf8)
        XCTAssertThrowsError(try IncomingMessage.decode(line: line)) { error in
            XCTAssertEqual(error as? KaraokeProtocolError, .notAnObject)
        }
    }
}
