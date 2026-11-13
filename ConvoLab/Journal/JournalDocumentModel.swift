import Foundation

@MainActor
@Observable
final class JournalDocumentModel {
    let entry: JournalEntryModel
    private(set) var isBusy = false
    var errorMessage: String?

    init(entry: JournalEntryModel) { self.entry = entry }

    var disabled: Bool { isBusy || entry.analysis?.pendingReplyId != nil }

    func toggle(_ suggestion: JournalCorrectedDocument.Suggestion) async -> Bool {
        guard let analysis = entry.analysis, let revision = analysis.replyRevision,
              let current = analysis.correctedDocument?.suggestions.first(where: { $0.id == suggestion.id }) else { return false }
        let payload = JournalSuggestionPayload(analysisId: analysis.id, expectedRevision: revision,
                                               suggestionId: current.id, applied: !current.applied)
        return await change { try await self.entry.store.service.suggestion(entryID: self.entry.id, body: payload) }
    }

    func save(_ payload: JournalCorrectedPayload) async -> Bool {
        await change { try await self.entry.store.service.corrected(entryID: self.entry.id, body: payload) }
    }

    private func change(_ request: () async throws -> JournalAnalysis) async -> Bool {
        guard !disabled else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let updated = try await request()
            return await accept(updated)
        } catch is CancellationError {
            return false
        } catch {
            try? await entry.refreshAnalysis()
            errorMessage = error.localizedDescription
            return false
        }
    }
    private func accept(_ updated: JournalAnalysis) async -> Bool {
        guard let current = entry.analysis, current.id == updated.id else {
            try? await entry.refreshAnalysis()
            errorMessage = "The entry changed. Reopen the editor to review its latest version."
            return false
        }
        guard let receivedRevision = updated.replyRevision,
              let currentRevision = current.replyRevision,
              receivedRevision >= currentRevision else {
            errorMessage = "A newer version arrived while saving. Your edits are still here; copy them before reopening the editor."
            return false
        }
        entry.analysis = updated
        return true
    }
}
