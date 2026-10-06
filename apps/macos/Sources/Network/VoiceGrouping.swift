// VoiceGrouping.swift — files a voice list into the groups pickers show.
//
// Kokoro alone lists 41 voices across seven language groups, and the user's
// own clips and blends come on top. Every picker (the Voices screen, the
// popover menu, App Voices) groups them the same way: the user's own first,
// then the engine's groups in the daemon's order.
import Foundation

public struct VoiceGroup: Sendable, Equatable, Identifiable {
    public let name: String
    public let voices: [Voice]
    public var id: String { name }
    /// The user's own clips or blends.
    public var isUserMade: Bool { voices.first?.isUserMade ?? false }
}

public extension Array where Element == Voice {
    /// Groups in display order; a voice without a group lands in "Voices".
    func grouped() -> [VoiceGroup] {
        var order: [String] = []
        var members: [String: [Voice]] = [:]
        for voice in self {
            let name = voice.group ?? "Voices"
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(voice)
        }
        let groups = order.map { VoiceGroup(name: $0, voices: members[$0] ?? []) }
        return groups.filter(\.isUserMade) + groups.filter { !$0.isUserMade }
    }

    /// The voice the daemon will actually use for `savedId`: the saved one
    /// when this engine has it, else the one the daemon marked default.
    func effectiveVoiceId(saved savedId: String?) -> String? {
        if let savedId, contains(where: { $0.id == savedId }) { return savedId }
        return first(where: \.isDefault)?.id
    }
}
