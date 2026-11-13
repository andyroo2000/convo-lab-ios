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
    private(set) var busyEntryIDs: Set<String> = []
    var errorMessage: String?

    init(api: APIClient, userID: Int, storageRoot: URL? = nil) {
        service = JournalService(api: api)
        storage = storageRoot.map { JournalDraftStorage(userID: userID, root: $0) } ?? JournalDraftStorage(userID: userID)
        refreshDrafts()
    }

    func refreshDrafts() {
        do {
            let listing = try storage.list()
            drafts = listing.drafts.filter { $0.rootEntryId == nil }
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
        guard entry.rootEntryId == nil else { return }
        if let current = entries.first(where: { $0.id == entry.id }), current.version > entry.version { return }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { ($0.entryDate, $0.id) > ($1.entryDate, $1.id) }
    }

    func beginMutation(id: String) throws {
        try service.checkSession()
        guard busyEntryIDs.insert(id).inserted else {
            throw APIClientError.rejected(status: 409, message: "This entry is still saving. Please try again when it finishes.")
        }
    }

    func endMutation(id: String) { busyEntryIDs.remove(id) }

    func delete(id: String) async throws {
        try beginMutation(id: id)
        defer { endMutation(id: id) }
        if let entry = entries.first(where: { $0.id == id }) {
            try await service.delete(id: id, version: entry.version)
        } else if let draft = try storage.load(id: id), draft.expectedVersion > 0 {
            try await service.delete(id: id, version: draft.expectedVersion)
        }
        entries.removeAll { $0.id == id }
        do {
            try storage.discardAnswers(id: id)
            for child in try storage.list().drafts where child.rootEntryId == id { try storage.discard(child) }
            if let draft = try storage.load(id: id) { try storage.discard(draft) }
        } catch {
            throw APIClientError.rejected(status: 503, message: "Online deletion succeeded, but the device copy could not be removed. Retry to clear it.")
        }
        refreshDrafts()
    }
}
