// VoiceLibraryTests.swift — the user's own voices over the wire, and how
// every picker groups a voice list. Network is stubbed via MockURLProtocol.
import XCTest

@testable import Myna

final class VoiceLibraryTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8766")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> DaemonClient {
        DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
    }

    private func voice(_ id: String, group: String?, kind: String = "builtin", isDefault: Bool = false) -> Voice {
        Voice(id: id, label: id, lang: "en", isDefault: isDefault, kind: kind, group: group)
    }

    // MARK: decoding

    func test_voice_list_decodes_engine_abilities_and_voice_facts() async throws {
        let body = Data("""
        {"voices": [
          {"id": "bf_emma", "label": "Emma", "lang": "en", "default": false, "kind": "builtin",
           "group": "British English", "gender": "female", "grade": "B-"},
          {"id": "clip-1a2b3c4d", "label": "Grandad", "lang": "en", "default": true, "kind": "clip",
           "group": "Your voices", "detail": "From a 9 s clip", "credit": "CSTR VCTK Corpus (CC BY 4.0)"}
         ],
         "active_engine": {"id": "pocket", "name": "Pocket TTS", "can_clone": true, "can_blend": false}}
        """.utf8)
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/voices")
            return (.make(url: req.url!, status: 200), body)  // swiftlint:disable:this force_unwrapping
        }
        let list = try await makeClient().voiceList()
        XCTAssertEqual(list.activeEngine, VoicesEngineInfo(id: "pocket", name: "Pocket TTS", canClone: true, canBlend: false))
        XCTAssertEqual(list.voices[0].grade, "B-")
        XCTAssertEqual(list.voices[0].gender, "female")
        XCTAssertFalse(list.voices[0].isUserMade)
        XCTAssertTrue(list.voices[1].isUserMade)
        XCTAssertEqual(list.voices[1].credit, "CSTR VCTK Corpus (CC BY 4.0)")
    }

    func test_old_voice_shape_still_decodes() throws {
        let data = try FixtureLoader.data("voices-response.json")
        let list = try JSONDecoder().decode(VoicesResponse.self, from: data)
        XCTAssertNil(list.activeEngine)
        XCTAssertNil(list.voices[0].kind)
        XCTAssertFalse(list.voices[0].isUserMade)
    }

    func test_library_voice_decodes() throws {
        let data = Data("""
        {"voices": [{"id": "vctk-p262", "name": "Edinburgh", "group": "Scottish", "gender": "female",
          "age": 23, "detail": "Scottish · VCTK p262", "license": "CC BY 4.0",
          "credit": "CSTR VCTK Corpus", "size_kb": 1044, "added_as": "clip-9f"}],
         "source": "Kyutai tts-voices"}
        """.utf8)
        let library = try JSONDecoder().decode(VoiceLibraryResponse.self, from: data)
        XCTAssertEqual(library.voices[0].sizeKb, 1044)
        XCTAssertEqual(library.voices[0].addedAs, "clip-9f")
        XCTAssertEqual(library.voices[0].age, 23)
    }

    // MARK: requests

    func test_add_clip_posts_the_wav_with_its_name() async throws {
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v2/voices/clips")
            XCTAssertEqual(req.url?.query, "name=My%20voice")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            let body = Data("""
            {"id": "clip-1", "label": "My voice", "lang": "en", "default": false, "kind": "clip"}
            """.utf8)
            return (.make(url: req.url!, status: 201), body)  // swiftlint:disable:this force_unwrapping
        }
        let added = try await makeClient().addClipVoice(wav: Data("RIFF".utf8), name: "My voice")
        XCTAssertEqual(added.id, "clip-1")
    }

    func test_refused_clip_surfaces_the_daemons_message() async {
        MockURLProtocol.enqueue { req in
            let body = Data("""
            {"detail": {"ok": false, "reason": "too_short", "detail": "The clip is 3.0 s. Use at least 5.5 seconds of speech."}}
            """.utf8)
            return (.make(url: req.url!, status: 400), body)  // swiftlint:disable:this force_unwrapping
        }
        do {
            _ = try await makeClient().addClipVoice(wav: Data(), name: "x")
            XCTFail("expected a refusal")
        } catch let error as VoiceActionError {
            XCTAssertEqual(error.reason, "too_short")
            XCTAssertEqual(error.message, "The clip is 3.0 s. Use at least 5.5 seconds of speech.")
        } catch {
            XCTFail("expected VoiceActionError, got \(error)")
        }
    }

    func test_blend_and_delete_hit_their_endpoints() async throws {
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/voices/blends")
            XCTAssertEqual(req.httpMethod, "POST")
            let body = Data("""
            {"id": "blend-1", "label": "Mix", "lang": "en", "default": false, "kind": "blend"}
            """.utf8)
            return (.make(url: req.url!, status: 201), body)  // swiftlint:disable:this force_unwrapping
        }
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/voices/custom/blend-1")
            XCTAssertEqual(req.httpMethod, "DELETE")
            return (.make(url: req.url!, status: 200), Data(#"{"ok": true}"#.utf8))  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let blend = try await client.addBlendVoice(
            name: "Mix", mix: [BlendPart(voice: "af_heart", weight: 3), BlendPart(voice: "bm_george", weight: 1)])
        try await client.deleteVoice(id: blend.id)
    }

    // MARK: grouping

    func test_grouping_puts_your_own_voices_first_and_keeps_engine_order() {
        let voices = [
            voice("af_heart", group: "American English"),
            voice("bf_emma", group: "British English"),
            voice("af_bella", group: "American English"),
            voice("blend-1", group: "Your blends", kind: "blend"),
            voice("mystery", group: nil),
        ]
        let groups = voices.grouped()
        XCTAssertEqual(groups.map(\.name), ["Your blends", "American English", "British English", "Voices"])
        XCTAssertEqual(groups[1].voices.map(\.id), ["af_heart", "af_bella"])
        XCTAssertTrue(groups[0].isUserMade)
    }

    func test_effective_voice_falls_back_to_the_engines_default() {
        let voices = [voice("alba", group: "Built-in", isDefault: true), voice("marius", group: "Built-in")]
        XCTAssertEqual(voices.effectiveVoiceId(saved: "marius"), "marius")
        // Saved on another engine: the daemon reads with this engine's default.
        XCTAssertEqual(voices.effectiveVoiceId(saved: "af_heart"), "alba")
        XCTAssertEqual(voices.effectiveVoiceId(saved: nil), "alba")
    }

    func test_popover_keeps_small_lists_inline_and_folds_long_ones() {
        let few = [voice("alba", group: "Built-in"), voice("clip-1", group: "Your voices", kind: "clip")].grouped()
        XCTAssertEqual(VoiceSpeedRow.inlineGroups(few, total: 2), ["Built-in", "Your voices"])

        let many = (0..<20).map { voice("a\($0)", group: "American English") }
            + (0..<8).map { voice("b\($0)", group: "British English") }
            + [voice("clip-1", group: "Your voices", kind: "clip")]
        XCTAssertEqual(
            VoiceSpeedRow.inlineGroups(many.grouped(), total: many.count), ["Your voices", "American English"])
    }
}
