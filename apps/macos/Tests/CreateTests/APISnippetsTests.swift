// APISnippetsTests.swift — the API pane's copy-paste examples are real
// code people will run, so they're checked with the real tools: bash
// parses the shell, python3 parses the Python, node checks the
// JavaScript, and the JSON bodies are decoded. Tools that aren't
// installed skip their test rather than fail it.
import XCTest

@testable import Myna

final class APISnippetsTests: XCTestCase {

    private let local = APISnippets.Context(
        baseURL: "http://127.0.0.1:8766/v1", voice: "af_heart", format: "mp3", apiKey: nil)

    private var lan: APISnippets.Context {
        var ctx = local
        ctx.baseURL = "http://192.168.1.20:8766/v1"
        ctx.apiKey = "myna-3f9c2a71d0b84e55a1b2"
        return ctx
    }

    /// Quotes, a newline, a backslash and a non-ASCII voice name: the
    /// things that break naive snippet templates.
    private var awkward: APISnippets.Context {
        var ctx = local
        ctx.voice = "Rosa's \"clone\" ✓"
        ctx.input = "It's a \\ test\nwith \"quotes\" and $HOME and `ticks`"
        return ctx
    }

    // MARK: - curl

    func test_curl_uses_the_real_url_voice_and_format() {
        let curl = APISnippets.curl(local)
        XCTAssertTrue(curl.hasPrefix("curl http://127.0.0.1:8766/v1/audio/speech"))
        XCTAssertTrue(curl.contains("\"voice\": \"af_heart\""))
        XCTAssertTrue(curl.contains("\"response_format\": \"mp3\""))
        XCTAssertTrue(curl.contains("--output speech.mp3"))
        XCTAssertFalse(curl.contains("Authorization"), "loopback never needs a key")
    }

    func test_curl_is_valid_shell_and_its_body_is_valid_json() throws {
        for ctx in [local, lan, awkward] {
            let curl = APISnippets.curl(ctx)
            try assertShellParses(curl)
            let body = try shellWords(curl).drop { $0 != "-d" }.dropFirst().first
            let json = try XCTUnwrap(body, "no -d argument in:\n\(curl)")
            let decoded = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
            XCTAssertEqual(decoded["voice"], ctx.voice)
            XCTAssertEqual(decoded["input"], ctx.input)
            XCTAssertEqual(decoded["response_format"], ctx.format)
            XCTAssertEqual(decoded["model"], "tts-1")
        }
    }

    func test_curl_for_another_device_sends_the_key_as_a_bearer_token() throws {
        let words = try shellWords(APISnippets.curl(lan))
        XCTAssertEqual(words[1], "http://192.168.1.20:8766/v1/audio/speech")
        XCTAssertTrue(words.contains("Authorization: Bearer myna-3f9c2a71d0b84e55a1b2"))
    }

    // MARK: - shell one-liner

    func test_shell_one_liner_speaks_wav_through_afplay() throws {
        let line = APISnippets.shell(local)
        XCTAssertFalse(line.contains("\n"), "it's a one-liner")
        XCTAssertTrue(line.hasSuffix("afplay /tmp/myna.wav"))
        XCTAssertTrue(line.contains("\"response_format\": \"wav\""), "afplay reads WAV and it needs no encoder")
        try assertShellParses(line)
        try assertShellParses(APISnippets.shell(lan))
        try assertShellParses(APISnippets.shell(awkward))
    }

    // MARK: - Python / JavaScript

    func test_python_is_valid_and_filled_in() throws {
        for ctx in [local, lan, awkward] {
            let code = APISnippets.python(ctx)
            XCTAssertTrue(code.contains("base_url=\"\(ctx.baseURL)\""))
            XCTAssertTrue(code.contains("voice=\(APISnippets.jsonString(ctx.voice))"))
            try assertPythonParses(code)
        }
        XCTAssertTrue(APISnippets.python(local).contains("api_key=\"myna\""), "SDKs need some key")
        XCTAssertTrue(APISnippets.python(lan).contains("api_key=\"myna-3f9c2a71d0b84e55a1b2\""))
    }

    func test_python_string_literals_round_trip() throws {
        let python = try tool(["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"])
        let script = "import sys; sys.stdout.write(\(APISnippets.jsonString(awkward.input)))"
        XCTAssertEqual(try run(python, ["-c", script]).stdout, awkward.input)
    }

    func test_node_and_fetch_are_valid_javascript() throws {
        for ctx in [local, lan, awkward] {
            let node = APISnippets.node(ctx)
            let fetch = APISnippets.fetch(ctx)
            XCTAssertTrue(node.contains("baseURL: \"\(ctx.baseURL)\""))
            XCTAssertTrue(fetch.contains("fetch(\"\(ctx.speechURL)\""))
            try assertJavaScriptParses(node)
            try assertJavaScriptParses(fetch)
        }
        XCTAssertTrue(APISnippets.fetch(lan).contains("Authorization: \"Bearer myna-3f9c2a71d0b84e55a1b2\""))
        XCTAssertFalse(APISnippets.fetch(local).contains("Authorization"))
    }

    // MARK: - steps and fields

    func test_shortcut_steps_name_the_url_and_only_ask_for_a_key_off_this_mac() {
        let steps = APISnippets.shortcutSteps(local)
        XCTAssertTrue(steps[0].contains("http://127.0.0.1:8766/v1/audio/speech"))
        XCTAssertFalse(steps.joined().contains("Authorization"))
        XCTAssertTrue(APISnippets.shortcutSteps(lan).joined().contains("Bearer myna-3f9c2a71d0b84e55a1b2"))
    }

    func test_app_fields_are_the_four_values_a_client_asks_for() {
        let fields = APISnippets.appFields(local)
        XCTAssertEqual(fields.map(\.label), ["Base URL", "API key", "Model", "Voice"])
        XCTAssertEqual(fields.map(\.value), ["http://127.0.0.1:8766/v1", "myna", "tts-1", "af_heart"])
        XCTAssertEqual(APISnippets.appFields(lan)[1].value, "myna-3f9c2a71d0b84e55a1b2")
    }

    // MARK: - choosing values

    func test_preferred_format_is_mp3_only_when_this_mac_can_make_it() {
        func format(_ id: String, _ available: Bool) -> AudioFormatInfo {
            AudioFormatInfo(id: id, label: id, available: available, ext: id, mime: "", reason: nil)
        }
        XCTAssertEqual(APISnippets.preferredFormat([format("wav", true), format("mp3", true)]), "mp3")
        XCTAssertEqual(APISnippets.preferredFormat([format("wav", true), format("mp3", false)]), "wav")
        XCTAssertEqual(APISnippets.preferredFormat([]), "wav")
    }

    func test_sample_voice_is_the_engine_default_then_first_then_an_openai_name() {
        let heart = Voice(id: "af_heart", label: "Heart", lang: "en", isDefault: false)
        let bella = Voice(id: "af_bella", label: "Bella", lang: "en", isDefault: true)
        XCTAssertEqual(APISnippets.sampleVoice([heart, bella]), "af_bella")
        XCTAssertEqual(APISnippets.sampleVoice([heart]), "af_heart")
        XCTAssertEqual(APISnippets.sampleVoice([]), "alloy")
    }

    func test_network_snippets_prefer_an_address_other_devices_can_reach() {
        // What this Mac's daemon reported on 29 Sep: the 192.0.0.2 first
        // entry refused connections even locally.
        let reported = [
            "http://192.0.0.2:8766/v1", "http://100.93.255.115:8766/v1", "http://Nebula.local:8766/v1",
        ]
        XCTAssertEqual(APISnippets.preferredLANURL(reported), "http://Nebula.local:8766/v1")
        XCTAssertEqual(
            APISnippets.preferredLANURL(reported + ["http://192.168.1.20:8766/v1"]), "http://192.168.1.20:8766/v1")
        XCTAssertEqual(
            APISnippets.preferredLANURL(["http://192.0.0.2:8766/v1", "http://100.93.255.115:8766/v1"]),
            "http://100.93.255.115:8766/v1")
        XCTAssertEqual(
            APISnippets.preferredLANURL(["http://172.20.0.4:8766/v1", "http://10.0.0.7:8766/v1"]),
            "http://172.20.0.4:8766/v1", "ties keep the daemon's order")
        XCTAssertNil(APISnippets.preferredLANURL([]))
    }

    func test_masked_key_hides_all_but_the_prefix_and_last_four() {
        XCTAssertEqual(APISnippets.maskedKey("myna-3f9c2a71d0b84e55a1b2"), "myna-••••••••a1b2")
        XCTAssertEqual(APISnippets.maskedKey("short"), "••••••••")
        XCTAssertFalse(APISnippets.maskedKey("abcdefghijklmnopqrstuvwxyz").contains("abcd"))
    }

    func test_json_string_escapes_decode_back_to_the_original() throws {
        let tricky = "quote \" backslash \\ newline \n tab \t bell \u{7} sep \u{2028} emoji 🐦"
        let literal = APISnippets.jsonString(tricky)
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)
        XCTAssertEqual(decoded as? String, tricky)
    }

    func test_shell_single_quoting_round_trips_through_bash() throws {
        let value = awkward.input + " it's"
        let out = try run("/bin/bash", ["-c", "printf %s \(APISnippets.shellSingleQuoted(value))"]).stdout
        XCTAssertEqual(out, value)
    }

    // MARK: - helpers

    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ path: String, _ args: [String]) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(bytes: stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: stderr, encoding: .utf8) ?? "")
    }

    private func tool(_ candidates: [String]) throws -> String {
        var paths = candidates
        if candidates.contains(where: { $0.hasSuffix("/node") }) {
            let nvm = (NSHomeDirectory() as NSString).appendingPathComponent(".nvm/versions/node")
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []
            paths += versions.sorted().reversed().map { "\(nvm)/\($0)/bin/node" }
        }
        guard let found = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("none of \(candidates) installed")
        }
        return found
    }

    private func assertShellParses(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try run("/bin/bash", ["-n", "-c", script])
        XCTAssertEqual(result.status, 0, "bash rejected:\n\(script)\n\(result.stderr)", file: file, line: line)
    }

    /// The words bash would pass to curl: the real test of the quoting.
    private func shellWords(_ script: String) throws -> [String] {
        let printer = "for w in \"$@\"; do printf '%s\\0' \"$w\"; done"
        let words = script.replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "curl ", with: "", options: .anchored)
        let result = try run("/bin/bash", ["-c", "set -- \(words); \(printer)"])
        XCTAssertEqual(result.status, 0, result.stderr)
        return ["curl"] + result.stdout.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init).dropLast()
    }

    private func assertPythonParses(_ code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let python = try tool(["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"])
        let check = "import ast, sys; ast.parse(sys.stdin.read())"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myna-snippet-\(UUID()).py")
        try code.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try run("/bin/bash", ["-c", "\(python) -c '\(check)' < '\(url.path)'"])
        XCTAssertEqual(result.status, 0, "python rejected:\n\(code)\n\(result.stderr)", file: file, line: line)
    }

    private func assertJavaScriptParses(_ code: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let node = try tool(["/opt/homebrew/bin/node", "/usr/local/bin/node"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myna-snippet-\(UUID()).mjs")
        try code.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try run(node, ["--check", url.path])
        XCTAssertEqual(result.status, 0, "node rejected:\n\(code)\n\(result.stderr)", file: file, line: line)
    }
}
