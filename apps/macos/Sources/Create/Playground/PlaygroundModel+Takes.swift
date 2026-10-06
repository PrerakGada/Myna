// PlaygroundModel+Takes.swift — what you can do with a take once it
// exists: play, seek, save, drag, copy, reveal, reuse, delete.
import Foundation

extension PlaygroundModel {

    func audioURL(for take: PlaygroundTake) -> URL {
        store.audioURL(for: take)
    }

    /// The engine's display name when it is the active one, else its id.
    func engineName(for take: PlaygroundTake) -> String? {
        guard let id = take.engine else { return nil }
        return engine?.id == id ? engine?.name : id
    }

    func select(_ take: PlaygroundTake) {
        selectedTakeId = take.id
    }

    // MARK: - playback

    func togglePlay(_ take: PlaygroundTake) {
        selectedTakeId = take.id
        player.toggle(id: take.id, url: audioURL(for: take))
    }

    func seek(_ take: PlaygroundTake, to fraction: Double) {
        selectedTakeId = take.id
        player.seek(id: take.id, url: audioURL(for: take), to: fraction)
    }

    /// Space bar. False when there is no selected take, so the key goes
    /// wherever it would have gone.
    func toggleSelectedPlayback() -> Bool {
        guard let take = selectedTake else { return false }
        togglePlay(take)
        return true
    }

    // MARK: - saving

    /// The format ⌘S uses: whatever was saved last, if still available.
    var quickSaveFormat: AudioFormatInfo {
        let last = defaults.string(forKey: Self.saveFormatKey)
        return formats.first { $0.id == last && $0.available } ?? PlaygroundExport.wav
    }

    func saveSelected() {
        guard let take = selectedTake else { return }
        save(take, as: quickSaveFormat)
    }

    func fileName(for take: PlaygroundTake, ext: String) -> String {
        PlaygroundText.defaultFileName(
            text: take.text,
            voice: take.isRecovered ? nil : take.voiceLabel,
            ext: ext
        )
    }

    func save(_ take: PlaygroundTake, as format: AudioFormatInfo) {
        guard format.available, !isSaving else { return }
        selectedTakeId = take.id
        guard let destination = PlaygroundExport.chooseDestination(
            defaultName: fileName(for: take, ext: format.ext), format: format)
        else { return }
        defaults.set(format.id, forKey: Self.saveFormatKey)
        setSaving(true)
        let source = audioURL(for: take)
        let render = self.render
        Task { [weak self] in
            do {
                try await PlaygroundExport.export(source: source, as: format, to: destination, using: render)
                self?.notice = PlaygroundNotice(
                    .info, "Saved \(destination.lastPathComponent).", action: .reveal(destination))
            } catch {
                self?.notice = PlaygroundErrors.notice(for: error)
            }
            self?.setSaving(false)
        }
    }

    // MARK: - out to other apps

    /// The take's audio under a readable name, for drags and the pasteboard.
    func shareableFile(for take: PlaygroundTake) -> URL? {
        PlaygroundExport.shareableFile(
            source: audioURL(for: take),
            takeId: take.id,
            fileName: fileName(for: take, ext: "wav")
        )
    }

    func copyAudio(_ take: PlaygroundTake) {
        guard let file = shareableFile(for: take) else {
            notice = PlaygroundNotice(.error, "This take's audio is missing from disk.")
            return
        }
        PlaygroundExport.copyFileToPasteboard(file)
        notice = PlaygroundNotice(.info, "Copied the audio file. Paste it into Finder or another app.")
    }

    func copyText(_ take: PlaygroundTake) {
        PlaygroundExport.copyTextToPasteboard(take.text)
    }

    func reveal(_ take: PlaygroundTake) {
        PlaygroundExport.reveal(audioURL(for: take))
    }

    // MARK: - reuse

    func useText(of take: PlaygroundTake) {
        guard !take.text.isEmpty else { return }
        draft.text = take.text
    }

    func useVoice(of take: PlaygroundTake) {
        guard voices.contains(where: { $0.id == take.voice }) else { return }
        voiceId = take.voice
    }

    // MARK: - deleting

    func delete(_ takes: [PlaygroundTake]) {
        let ids = Set(takes.map(\.id))
        for id in ids { player.release(id: id) }
        store.delete(ids: ids)
        if let selectedTakeId, ids.contains(selectedTakeId) { self.selectedTakeId = nil }
    }

    func deleteAllTakes() {
        player.stop()
        store.deleteAll()
        selectedTakeId = nil
    }
}
