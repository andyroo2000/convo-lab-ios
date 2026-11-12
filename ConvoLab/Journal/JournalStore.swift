import Foundation

@Observable
final class JournalStore {
    // Avoid the Swift 6.2 isolated-deinit runtime path; no actor work is needed here.
    nonisolated deinit {}
    let service: JournalService
    let storage: JournalDraftStorage
    private(set) var entries: [JournalEntry] = []
    private(set) var drafts: [JournalDraft] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    var errorMessage: String?

    init(api: APIClient, userID: Int, storageRoot: URL? = nil) {
        service = JournalService(api: api)
        storage = storageRoot.map { JournalDraftStorage(userID: userID, root: $0) } ?? JournalDraftStorage(userID: userID)
        refreshDrafts()
    }

    func refreshDrafts() {
        do {
            let listing = try storage.list()
            drafts = listing.drafts
            if listing.unreadableCount > 0 {
                errorMessage = "Some device drafts could not be opened. Their original files have been retained."
            }
        } catch { errorMessage = "Device drafts could not be read. Keep any open writing on screen." }
    }

    func loadMore(refresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await service.archive(cursor: refresh ? nil : nextCursor)
            if refresh { entries = [] }
            for entry in result.data { accept(entry) }
            nextCursor = result.nextCursor
            errorMessage = nil
            refreshDrafts()
        } catch { errorMessage = "Saved entries are unavailable. Device drafts are still here." }
    }

    func create() throws -> JournalDraft {
        try service.checkSession()
        let draft = JournalDraft.new()
        try storage.save(draft)
        refreshDrafts()
        return draft
    }

    func write(_ draft: JournalDraft) throws {
        try service.checkSession()
        try storage.save(draft)
        refreshDrafts()
    }

    func accept(_ entry: JournalEntry) {
        if let current = entries.first(where: { $0.id == entry.id }), current.version > entry.version { return }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }
    }

    func delete(id: String) async throws {
        try service.checkSession()
        if let entry = entries.first(where: { $0.id == id }) {
            try await service.delete(entry)
        } else if let draft = try storage.load(id: id), draft.expectedVersion > 0 {
            let current = try await service.entry(id)
            try await service.delete(current)
        }
        if let draft = try storage.load(id: id) { try storage.discard(draft) }
        entries.removeAll { $0.id == id }
        refreshDrafts()
    }
}
