import Foundation

nonisolated struct JournalConversationNode: Codable, Identifiable, Sendable {
    var id: String { entry.id }
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
    func load() async {
        do {
            nodes = try await root.store.service.conversation(root.id)
            loaded = true
            errorMessage = nil
        } catch is CancellationError { }
        catch { errorMessage = "The conversation could not be loaded. Please retry." }
    }
}
