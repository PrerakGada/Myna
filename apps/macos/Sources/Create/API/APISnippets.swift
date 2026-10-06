// APISnippets.swift — the copy-paste examples on the API pane, generated
// from the real base URL, a real voice of the active engine and a format
// this Mac can actually encode.
//
// Pure on purpose: every string here ends up in someone's terminal or
// editor, so the generator is unit-tested for valid shell, valid Python
// and valid JSON (APISnippetsTests). Views only render what this returns.
import Foundation

enum APISnippets {

    /// One tab of the Quick start card.
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case curl
        case python
        case node
        case fetch
        case shell
        case shortcuts
        case apps

        var id: String { rawValue }

        var label: String {
            switch self {
            case .curl: return "curl"
            case .python: return "Python"
            case .node: return "Node"
            case .fetch: return "fetch"
            case .shell: return "Shell"
            case .shortcuts: return "Shortcuts"
            case .apps: return "Apps"
            }
        }

        /// Small caption above the code block.
        var caption: String {
            switch self {
            case .curl: return "Save a clip to a file."
            case .python: return "The official openai package (pip install openai)."
            case .node: return "The official openai package (npm install openai), as an ES module."
            case .fetch: return "No dependencies. Node 18 or later."
            case .shell: return "Speak out loud on this Mac through afplay."
            case .shortcuts: return "Apple Shortcuts, on this Mac or another device."
            case .apps: return "Any app that lets you set an OpenAI base URL and key."
            }
        }

        /// Tabs that render as a code block (the rest are steps or fields).
        var isCode: Bool { self != .shortcuts && self != .apps }
    }

    /// What every snippet is filled with.
    struct Context: Equatable, Sendable {
        /// `http://127.0.0.1:8766/v1` — no trailing slash.
        var baseURL: String
        /// A voice id of the active engine, or an OpenAI name as fallback.
        var voice: String
        /// `mp3`, `wav`, … — one this Mac can encode.
        var format: String
        /// nil on this Mac (loopback never needs one); the real key for the
        /// network version.
        var apiKey: String?
        var input: String = "Hello from Myna."
        var model: String = "tts-1"

        var speechURL: String { baseURL + "/audio/speech" }

        /// File extension for the saved clip (`opus` is Ogg Opus, and
        /// `.opus` is what players expect for it).
        var fileExtension: String { format }

        /// The key an OpenAI SDK is given. SDKs refuse to start without
        /// one, so on this Mac any placeholder does.
        var sdkKey: String { apiKey ?? "myna" }
    }

    /// OpenAI's voice names; the daemon maps each to one of the active
    /// engine's voices (RENDER_API.md § 1).
    static let openAIVoiceNames = [
        "alloy", "ash", "ballad", "coral", "echo", "fable",
        "onyx", "nova", "sage", "shimmer", "verse",
    ]

    /// Formats a browser/afplay/QuickTime can all open, in the order the
    /// snippets prefer them. MP3 is OpenAI's default, so it wins when this
    /// Mac can make it; WAV is always available.
    static func preferredFormat(_ formats: [AudioFormatInfo]) -> String {
        let available = Set(formats.filter(\.available).map(\.id))
        if available.contains("mp3") { return "mp3" }
        return "wav"
    }

    /// The voice the snippets name: the engine's default (what the API
    /// uses when no voice is sent), else its first voice, else an OpenAI
    /// name, which every engine accepts.
    static func sampleVoice(_ voices: [Voice]) -> String {
        if let preferred = voices.first(where: \.isDefault) { return preferred.id }
        return voices.first?.id ?? "alloy"
    }

    /// Which of the daemon's `lan_urls` the snippets for another device
    /// use. The daemon lists every non-loopback IPv4 address plus the
    /// Bonjour name, in interface order, and the first isn't always one a
    /// phone can reach (a 192.0.0.x address from an IPv6-only network's
    /// translation layer didn't even answer from this Mac). Home-network
    /// addresses first, then `<name>.local`, then the rest (Tailscale's
    /// 100.x and the like), with 192.0.0.x last.
    static func preferredLANURL(_ urls: [String]) -> String? {
        func rank(_ raw: String) -> Int {
            guard let host = URL(string: raw)?.host?.lowercased() else { return 4 }
            if host.hasSuffix(".local") { return 1 }
            let octets = host.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { return 2 }
            if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 172 && (16...31).contains(octets[1])) {
                return 0
            }
            if octets[0] == 192 && octets[1] == 0 && octets[2] == 0 { return 3 }
            return 2
        }
        return urls.enumerated()
            .min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?
            .element
    }

    /// `myna-3f…` → `myna-••••••••a1b2`. Keeps enough to tell two keys
    /// apart without showing one to a screen-share.
    static func maskedKey(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        let prefix = key.hasPrefix("myna-") ? "myna-" : ""
        return prefix + String(repeating: "•", count: 8) + key.suffix(4)
    }

    // MARK: - snippets

    static func snippet(_ kind: Kind, _ ctx: Context) -> String {
        switch kind {
        case .curl: return curl(ctx)
        case .python: return python(ctx)
        case .node: return node(ctx)
        case .fetch: return fetch(ctx)
        case .shell: return shell(ctx)
        case .shortcuts:
            return shortcutSteps(ctx).enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        case .apps:
            return appFields(ctx).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        }
    }

    /// The JSON request body, pretty enough to read inside a snippet.
    static func jsonBody(_ ctx: Context, indent: String = "  ", includeModel: Bool = true) -> String {
        var fields: [(String, String)] = []
        if includeModel { fields.append(("model", ctx.model)) }
        fields.append(("voice", ctx.voice))
        fields.append(("input", ctx.input))
        fields.append(("response_format", ctx.format))
        let lines = fields.map { "\(indent)  \(jsonString($0.0)): \(jsonString($0.1))" }
        return "{\n" + lines.joined(separator: ",\n") + "\n\(indent)}"
    }

    static func curl(_ ctx: Context) -> String {
        var lines = ["curl \(ctx.speechURL) \\", "  -H \"Content-Type: application/json\" \\"]
        if let key = ctx.apiKey {
            lines.append("  -H \(shellSingleQuoted("Authorization: Bearer " + key)) \\")
        }
        lines.append("  -d \(shellSingleQuoted(jsonBody(ctx))) \\")
        lines.append("  --fail --output speech.\(ctx.fileExtension)")
        return lines.joined(separator: "\n")
    }

    static func python(_ ctx: Context) -> String {
        let keyComment = ctx.apiKey == nil ? "  # any key works on this Mac" : ""
        return """
            from openai import OpenAI

            client = OpenAI(
                base_url=\(jsonString(ctx.baseURL)),
                api_key=\(jsonString(ctx.sdkKey)),\(keyComment)
            )

            with client.audio.speech.with_streaming_response.create(
                model=\(jsonString(ctx.model)),
                voice=\(jsonString(ctx.voice)),
                input=\(jsonString(ctx.input)),
                response_format=\(jsonString(ctx.format)),
            ) as response:
                response.stream_to_file("speech.\(ctx.fileExtension)")
            """
    }

    static func node(_ ctx: Context) -> String {
        let keyComment = ctx.apiKey == nil ? " // any key works on this Mac" : ""
        return """
            import fs from "node:fs";
            import OpenAI from "openai";

            const openai = new OpenAI({
              baseURL: \(jsonString(ctx.baseURL)),
              apiKey: \(jsonString(ctx.sdkKey)),\(keyComment)
            });

            const speech = await openai.audio.speech.create({
              model: \(jsonString(ctx.model)),
              voice: \(jsonString(ctx.voice)),
              input: \(jsonString(ctx.input)),
              response_format: \(jsonString(ctx.format)),
            });
            fs.writeFileSync("speech.\(ctx.fileExtension)", Buffer.from(await speech.arrayBuffer()));
            """
    }

    static func fetch(_ ctx: Context) -> String {
        var headers = ["\"Content-Type\": \"application/json\""]
        if let key = ctx.apiKey {
            headers.append("Authorization: \(jsonString("Bearer " + key))")
        }
        return """
            import fs from "node:fs";

            const res = await fetch(\(jsonString(ctx.speechURL)), {
              method: "POST",
              headers: { \(headers.joined(separator: ", ")) },
              body: JSON.stringify(\(jsonBody(ctx, indent: "  "))),
            });
            if (!res.ok) throw new Error((await res.json()).error.message);
            fs.writeFileSync("speech.\(ctx.fileExtension)", Buffer.from(await res.arrayBuffer()));
            """
    }

    /// One line: synthesize to a temp file, then play it. Always WAV —
    /// afplay reads it, and it costs no encoding time.
    static func shell(_ ctx: Context) -> String {
        var wav = ctx
        wav.format = "wav"
        wav.input = "Build finished."
        let body = "{\"voice\": \(jsonString(wav.voice)), \"input\": \(jsonString(wav.input)), "
            + "\"response_format\": \"wav\"}"
        var parts = ["curl -sf \(wav.speechURL)", "-H 'Content-Type: application/json'"]
        if let key = wav.apiKey {
            parts.append("-H \(shellSingleQuoted("Authorization: Bearer " + key))")
        }
        parts.append("-d \(shellSingleQuoted(body))")
        parts.append("-o /tmp/myna.wav && afplay /tmp/myna.wav")
        return parts.joined(separator: " ")
    }

    // MARK: - steps and fields

    /// Apple Shortcuts, in words: Shortcuts has no text format to paste.
    static func shortcutSteps(_ ctx: Context) -> [String] {
        var steps = [
            "Add a Get Contents of URL action and set the URL to \(ctx.speechURL)",
            "Open its options. Set Method to POST and Request Body to JSON.",
            "Add three Text fields: input (the words to speak, or Shortcut Input), "
                + "voice = \(ctx.voice), response_format = wav",
        ]
        if let key = ctx.apiKey {
            steps.append("Under Headers, add Authorization = Bearer \(key)")
        }
        steps.append("Add Play Sound to hear the result, or Save File to keep it.")
        return steps
    }

    struct Field: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        let note: String?
        var id: String { label }
    }

    /// The four values every OpenAI-compatible client asks for.
    static func appFields(_ ctx: Context) -> [Field] {
        [
            Field(label: "Base URL", value: ctx.baseURL, note: nil),
            Field(
                label: "API key",
                value: ctx.sdkKey,
                note: ctx.apiKey == nil ? "Anything. Apps on this Mac aren't asked for a key." : nil),
            Field(label: "Model", value: ctx.model, note: "Any of tts-1, tts-1-hd or myna picks the active engine."),
            Field(label: "Voice", value: ctx.voice, note: "Or an OpenAI name such as alloy or nova."),
        ]
    }

    // MARK: - quoting

    /// A double-quoted string literal valid in JSON, Python and JavaScript.
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// POSIX single-quoting: the only character that needs care is `'`.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
