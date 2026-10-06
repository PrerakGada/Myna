// BoldClaims.swift — pull the **bold** claims out of a Claude Code reply so
// Myna can read just those instead of the whole thing.
//
// Works when the writer bolds whole claims ("reading only the bold should
// give the gist"), which is why it's an opt-in setting rather than the
// default: a reply that bolds single keywords would read as fragments.
// Anything inside code (fenced blocks, inline backticks) is literal, never a
// claim. A reply with no bold returns nil so callers read it in full rather
// than going silent.
import Foundation

public enum BoldClaims {

    /// The bold claims joined into one speakable paragraph, or nil when the
    /// text has none.
    public static func spokenText(from markdown: String) -> String? {
        let claims = extract(from: markdown)
        return claims.isEmpty ? nil : claims.joined(separator: " ")
    }

    /// Each bold span, cleaned for speech and ending in punctuation.
    public static func extract(from markdown: String) -> [String] {
        let prose = markdown
            .replacingOccurrences(of: #"(?s)```.*?(```|$)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"`[^`\n]*`"#, with: " ", options: .regularExpression)

        // CommonMark flanking: an opening ** is followed by non-space and a
        // closing ** preceded by one, so a stray unclosed ** can't pair with
        // the next bold span and read the words between them.
        let pattern = #"\*\*(?=\S)([^\n]+?)(?<=\S)\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = prose as NSString
        var claims: [String] = []
        for match in regex.matches(in: prose, range: NSRange(location: 0, length: ns.length)) {
            guard let claim = clean(ns.substring(with: match.range(at: 1))) else { continue }
            if claims.last != claim { claims.append(claim) }
        }
        return claims
    }

    /// Strip inline markup, drop "Label:" spans, and close with a full stop
    /// so the voice pauses between claims.
    static func clean(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[*_]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard text.contains(where: \.isLetter) else { return nil }
        // "**Why:**" / "**Next step:**" label a paragraph; alone they're noise.
        if text.hasSuffix(":") {
            let words = text.split(separator: " ").count
            if words <= 4 { return nil }
            text.removeLast()
        }
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text
    }
}
