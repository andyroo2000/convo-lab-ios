import Foundation

@MainActor
@Observable
final class JournalVoiceSelection {
    private(set) var voices: [JournalVoice] = []
    var selected = ""
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private var generation = 0
    private var loadedKey: String?

    var isReady: Bool { !isLoading && errorMessage == nil && voices.contains(where: { $0.id == selected }) }

    func load(entryID: String, analysis: JournalAnalysis, service: JournalService, snapshotURL: URL? = nil) async {
        let key = "\(entryID):\(analysis.id):\(analysis.replyRevision ?? 0)"
        guard !Task.isCancelled, loadedKey != key else { return }
        loadedKey = nil
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        selected = ""
        defer { if request == generation { isLoading = false } }
        await restoreDisplay(analysis: analysis, url: snapshotURL, request: request)
        guard request == generation, !Task.isCancelled else { return }
        do {
            async let catalog = loadCatalog(service)
            async let saved = service.audioState(entryID: entryID, analysisID: analysis.id, revision: analysis.replyRevision ?? 0)
            let (available, state) = try await (catalog, saved)
            guard request == generation else { return }
            try Task.checkCancellation()
            voices = available
            selected = available.first(where: { $0.id == state.voiceId })?.id ?? ""
            if let url = JournalAvatarCache.shared.resolve(available.first(where: { $0.id == selected })?.avatarUrl) {
                _ = await JournalAvatarCache.shared.storedImage(for: url)
            }
            guard request == generation, !Task.isCancelled else { return }
            if !available.isEmpty {
                loadedKey = key
                await JournalNarratorSnapshot.shared.write(.init(analysisID: analysis.id,
                    revision: analysis.replyRevision ?? 0, voices: available, selected: selected), to: snapshotURL)
            }
            if available.isEmpty { errorMessage = "No narration voices are available. Try again." }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = "Could not load your saved voice. Try again."
        }
    }

    private func loadCatalog(_ service: JournalService) async throws -> [JournalVoice] {
        let catalog = try await service.voices()
        try Task.checkCancellation()
        JournalAvatarCache.shared.preload(catalog.map(\.avatarUrl))
        return catalog
    }

    private func restoreDisplay(analysis: JournalAnalysis, url: URL?, request: Int) async {
        guard let saved = await JournalNarratorSnapshot.shared.read(url), saved.analysisID == analysis.id,
              saved.revision == analysis.replyRevision ?? 0 else { return }
        if let avatar = JournalAvatarCache.shared.resolve(saved.voices.first(where: { $0.id == saved.selected })?.avatarUrl) {
            _ = await JournalAvatarCache.shared.storedImage(for: avatar)
        }
        guard request == generation, !Task.isCancelled else { return }
        voices = saved.voices
        selected = saved.selected
        JournalAvatarCache.shared.preload(saved.voices.map(\.avatarUrl))
    }

    func cancel() {
        generation += 1
        isLoading = false
        if loadedKey == nil { selected = "" }
    }
}
