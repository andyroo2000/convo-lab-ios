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
        guard let analysis = entry.analysis else { return false }
        let payload = JournalSuggestionPayload(analysisId: analysis.id, expectedRevision: analysis.replyRevision ?? 0,
                                               suggestionId: suggestion.id, applied: !suggestion.applied)
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
            guard entry.analysis?.id == updated.id else { return false }
            entry.analysis = updated
            return true
        } catch {
            try? await entry.refreshAnalysis()
            errorMessage = error.localizedDescription
            return false
        }
    }
}
