import Foundation

nonisolated struct JournalConversationNode: Codable, Identifiable, Sendable {
    var id: String { entry.id }
    var revision: String { "\(entry.version):\(analysis?.id ?? ""):\(analysis?.updatedAt ?? "")" }
    let entry: JournalEntry
    let analysis: JournalAnalysis?
    let question: JournalTutorQuestion?
    let parentEntryId: String?
}

nonisolated struct JournalConversationInput: Codable, Sendable {
    let id: String
    let questionId: String
    let body: String
}

@MainActor
@Observable
final class JournalConversationModel {
    let root: JournalEntryModel
    private(set) var nodes: [JournalConversationNode] = []
    private(set) var loaded = false
    private(set) var errorMessage: String?

    init(root: JournalEntryModel) { self.root = root }
    @discardableResult
    func load() async -> Bool {
        do {
            nodes = try await root.store.service.conversation(root.id)
            loaded = true
            errorMessage = nil
            return true
        } catch is CancellationError { }
        catch { errorMessage = "The conversation could not be loaded. Please retry." }
        return false
    }
}
