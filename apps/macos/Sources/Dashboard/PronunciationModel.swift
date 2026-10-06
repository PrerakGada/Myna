// PronunciationModel.swift — the Pronunciation pane's state, the ▶ test
// player, and the word picker History's "Fix pronunciation…" uses.
//
// The daemon owns the list (PronunciationClient); this mirrors its last
// answer. The test player synthesizes the respelling through the render
// API's /v1/audio/speech and plays it through its own AVAudioPlayer, with
// no delegate: a finished-playing callback is exactly the kind of system
// callback that has crashed this app off the main actor before.
import AVFoundation
import Combine
import Foundation

@MainActor
final class PronunciationModel: ObservableObject {
    @Published private(set) var list: PronunciationList = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var loaded = false
    @Published var lastError: String?

    private let client: PronunciationClient

    init(client: PronunciationClient) {
        self.client = client
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        await apply { try await self.client.list() }
        loaded = true
    }

    /// Returns the daemon's refusal, if it refused.
    @discardableResult
    func add(word: String, say: String) async -> String? {
        await apply { try await self.client.add(word: word, say: say) }
    }

    @discardableResult
    func edit(_ entry: PronunciationEntry, word: String? = nil, say: String? = nil, enabled: Bool? = nil) async
        -> String? {
        await apply { try await self.client.edit(id: entry.id, word: word, say: say, enabled: enabled) }
    }

    func delete(_ entry: PronunciationEntry) async {
        await apply { try await self.client.delete(id: entry.id) }
    }

    func setStarter(enabled: Bool) async {
        await apply { try await self.client.setStarter(enabled: enabled) }
    }

    func setStarter(_ entry: StarterPronunciation, enabled: Bool) async {
        await apply { try await self.client.setStarterEntry(id: entry.id, enabled: enabled) }
    }

    @discardableResult
    private func apply(_ call: () async throws -> PronunciationList) async -> String? {
        do {
            list = try await call()
            lastError = nil
            return nil
        } catch let error as PronunciationError {
            lastError = error.message
            return error.message
        } catch {
            lastError = error.localizedDescription
            return error.localizedDescription
        }
    }

    /// Entries whose word or respelling contains `query` (case-insensitive).
    static func filter(_ list: PronunciationList, query: String)
        -> (mine: [PronunciationEntry], starter: [StarterPronunciation]) {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let mine = list.entries.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        let starter = list.starter.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        guard !needle.isEmpty else { return (mine, starter) }
        return (
            mine.filter { $0.word.lowercased().contains(needle) || $0.say.lowercased().contains(needle) },
            starter.filter { $0.word.lowercased().contains(needle) || $0.say.lowercased().contains(needle) }
        )
    }
}

/// Plays a respelling so the user can hear it before (or after) saving.
@MainActor
final class PronunciationTester: ObservableObject {
    /// The key of the row whose test is being synthesized.
    @Published private(set) var loadingKey: String?
    @Published private(set) var failure: String?

    private let client: RenderClient
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    init(client: RenderClient) {
        self.client = client
    }

    func play(_ say: String, key: String) {
        let text = say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel()
        player?.stop()
        failure = nil
        loadingKey = key
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let request = SpeechRequest(input: text, responseFormat: "wav", mynaPrep: .literal)
                let result = try await self.client.speech(request)
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(data: result.audio)
                self.player = player
                player.play()
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    self.failure = "Couldn't play it: Myna's background service didn't make the audio."
                }
            }
            if self.loadingKey == key { self.loadingKey = nil }
        }
    }

    func stop() {
        task?.cancel()
        player?.stop()
        loadingKey = nil
    }
}

/// The words of a read, for picking the one to fix.
enum PronunciationWords {
    /// Distinct words in order of first appearance, case-insensitively,
    /// with surrounding punctuation and a possessive "'s" trimmed. Inner
    /// punctuation stays, so "Node.js", "C++", "a11y" and "UI/UX" survive.
    static func candidates(in text: String, limit: Int = 300) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let edge = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "+#"))
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(raw).trimmingCharacters(in: edge)
            for suffix in ["'s", "’s"] where word.lowercased().hasSuffix(suffix) {
                word = String(word.dropLast(suffix.count))
            }
            word = word.trimmingCharacters(in: edge)
            guard word.count >= 2, word.contains(where: \.isLetter) else { continue }
            if seen.insert(word.lowercased()).inserted {
                out.append(word)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
