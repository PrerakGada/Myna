// HandsFreeText.swift — what Claude Code hands-free actually says.
//
//   HandsFreePhrasing  the short spoken alert ("myna needs you, permission
//                      to run a command") and the project prefix on replies.
//                      Built here, app-side, so the wording can change
//                      without replacing the hook installed on every Mac.
//   ReplySegmenter     cuts a reply into passages of a paragraph or so. The
//                      auto-read plays one passage at a time, which is what
//                      lets it stop cleanly at a boundary when the user
//                      comes back instead of mid-word.
import Foundation

public enum HandsFreePhrasing {
    /// A project folder name as it should sound: "Gala-ERP" → "Gala ERP".
    public static func spokenProject(_ projectId: String) -> String {
        let spaced = projectId.map { "-_.".contains($0) ? " " : $0 }
        let name = String(spaced).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return name.isEmpty ? "Claude" : name
    }

    /// Said before a reply so several sessions can be told apart by ear.
    public static func replyPrefix(projectId: String) -> String {
        "From \(spokenProject(projectId))."
    }

    /// The line spoken for a "needs you" entry, or nil for anything else.
    /// Kept to about eight words plus the project name.
    public static func alertLine(for item: RegistryV2Item) -> String? {
        guard item.isAttention else { return nil }
        let name = spokenProject(item.projectId)
        let message = item.text ?? item.title
        switch item.notificationType {
        case "permission_prompt":
            guard let action = permissionAction(message: message) else {
                return "\(name) needs your permission"
            }
            return "\(name) needs you, permission to \(action)"
        case "idle_prompt":
            return "\(name) is waiting for you"
        case "elicitation_dialog", "elicitation_url_dialog":
            return "\(name) has a question for you"
        case "agent_needs_input":
            return "\(name) needs your input"
        default:
            return "\(name) needs you"
        }
    }

    /// "Claude needs your permission to use Bash" → "run a command".
    /// Also reads the older "Allow Bash tool use?" wording.
    static func permissionAction(message: String) -> String? {
        let patterns = [#"permission to use ([A-Za-z0-9_:\-]+)"#, #"[Aa]llow ([A-Za-z0-9_:\-]+) tool"#]
        let range = NSRange(message.startIndex..., in: message)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: message, range: range),
                  let toolRange = Range(match.range(at: 1), in: message)
            else { continue }
            return action(forTool: String(message[toolRange]))
        }
        return nil
    }

    static func action(forTool tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell", "PowerShell": return "run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "edit files"
        case "Read": return "read a file"
        case "WebFetch": return "fetch a web page"
        case "WebSearch": return "search the web"
        case "Glob", "Grep": return "search files"
        case "Task", "Agent": return "start an agent"
        default:
            if tool.hasPrefix("mcp__") {
                let server = tool.dropFirst("mcp__".count).components(separatedBy: "__").first ?? ""
                let spoken = spokenProject(server)
                return spoken == "Claude" ? "use a tool" : "use \(spoken)"
            }
            return "use \(tool)"
        }
    }
}

public enum ReplySegmenter {
    /// Upper bound for one passage: roughly 35–40 seconds of speech. Larger
    /// means fewer pauses between passages; smaller means a returning user
    /// waits less for the current one to end.
    public static let maxChars = 600

    /// Split a reply into passages of whole paragraphs, packed up to
    /// `maxChars`. A paragraph longer than that is split between sentences,
    /// and a single sentence longer than that at a word boundary. Never
    /// drops a word; only whitespace inside a split paragraph can change.
    public static func passages(of text: String, maxChars: Int = ReplySegmenter.maxChars) -> [String] {
        let limit = max(40, maxChars)
        let paragraphs = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .reduce(into: [[String]]([[]])) { groups, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !(groups.last?.isEmpty ?? true) { groups.append([]) }
                } else {
                    groups[groups.count - 1].append(line)
                }
            }
            .map { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var pieces: [String] = []
        for paragraph in paragraphs {
            let parts = paragraph.count > limit ? split(paragraph, limit: limit) : [paragraph]
            for part in parts {
                if let last = pieces.last, last.count + 2 + part.count <= limit {
                    pieces[pieces.count - 1] = last + "\n\n" + part
                } else {
                    pieces.append(part)
                }
            }
        }
        return pieces
    }

    /// Split one long paragraph between sentences (or list lines).
    private static func split(_ paragraph: String, limit: Int) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for char in paragraph {
            if char.isWhitespace, let prev = previous, ".!?…:\n".contains(prev) || char == "\n" {
                if !current.isEmpty { sentences.append(current) }
                current = ""
                previous = char
                continue
            }
            if !(current.isEmpty && char.isWhitespace) { current.append(char) }
            previous = char
        }
        if !current.isEmpty { sentences.append(current) }

        var chunks: [String] = []
        var chunk = ""
        for sentence in sentences.flatMap({ hardWrap($0, limit: limit) }) {
            if chunk.isEmpty {
                chunk = sentence
            } else if chunk.count + 1 + sentence.count <= limit {
                chunk += " " + sentence
            } else {
                chunks.append(chunk)
                chunk = sentence
            }
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    /// Last resort for a "sentence" longer than the limit: break at spaces.
    private static func hardWrap(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var out: [String] = []
        var line = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + 1 + word.count <= limit {
                line += " " + word
            } else {
                out.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { out.append(line) }
        return out
    }
}
