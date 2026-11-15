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

    func load(entryID: String, analysis: JournalAnalysis, service: JournalService) async {
        let key = "\(entryID):\(analysis.id):\(analysis.replyRevision ?? 0)"
        guard !Task.isCancelled, loadedKey != key else { return }
        loadedKey = nil
        generation += 1
        let request = generation
        isLoading = true
        errorMessage = nil
        selected = ""
        defer { if request == generation { isLoading = false } }
        do {
            async let catalog = service.voices()
            async let saved = service.audioState(entryID: entryID, analysisID: analysis.id, revision: analysis.replyRevision ?? 0)
            let (available, state) = try await (catalog, saved)
            guard request == generation else { return }
            try Task.checkCancellation()
            voices = available
            JournalAvatarCache.shared.preload(available.map(\.avatarUrl))
            selected = available.first(where: { $0.id == state.voiceId })?.id ?? ""
            if !available.isEmpty { loadedKey = key }
            if available.isEmpty { errorMessage = "No narration voices are available. Try again." }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            errorMessage = "Could not load your saved voice. Try again."
        }
    }

    func cancel() {
        generation += 1
        isLoading = false
        if loadedKey == nil { selected = "" }
    }
}
