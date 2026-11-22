import Foundation

@Observable
final class JournalStore {
    // Avoid the Swift 6.2 isolated-deinit runtime path; no actor work is needed here.
    nonisolated deinit {}
    let service: JournalService
    let storage: JournalDraftStorage
    let synchronization: JournalDraftSync
    private(set) var entries: [JournalEntry] = []
    private(set) var drafts: [JournalDraft] = []
    private(set) var nextCursor: String?
    private(set) var isLoading = false
    private var refreshRequested = false
    private var acceptedVersions: [String: Int] = [:]
    private(set) var busyEntryIDs: Set<String> = []
    var errorMessage: String?

    init(api: APIClient, userID: Int, storageRoot: URL? = nil) {
        service = JournalService(api: api)
        storage = storageRoot.map { JournalDraftStorage(userID: userID, root: $0) } ?? JournalDraftStorage(userID: userID)
        synchronization = JournalDraftSync(service: service, drafts: storage)
        refreshDrafts()
    }

    func refreshDrafts() {
        do {
            let listing = try storage.list()
            let next = listing.drafts.filter { $0.rootEntryId == nil }
            if drafts != next { drafts = next }
            if listing.unreadableCount > 0 {
                errorMessage = "Some device drafts could not be opened. Their original files have been retained."
            }
        } catch { errorMessage = "Device drafts could not be read. Keep any open writing on screen." }
    }

    func loadMore(refresh: Bool = false) async {
        guard !isLoading else {
            if refresh { refreshRequested = true }
            return
        }
        isLoading = true
        defer { finishLoading() }
        let knownVersions = acceptedVersions
        do {
            let result = try await service.archive(cursor: refresh ? nil : nextCursor)
            if refresh { entries = [] }
            for entry in result.data { accept(entry) }
            applyReceipts(newerThan: knownVersions)
            nextCursor = result.nextCursor
            errorMessage = nil
            refreshDrafts()
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { errorMessage = "Saved entries are unavailable. Device drafts are still here." }
    }

    private func finishLoading() {
        isLoading = false
        guard refreshRequested else { return }
        refreshRequested = false
        // A foreground refresh must survive cancellation of the older sheet task.
        Task { [weak self] in await self?.loadMore(refresh: true) }
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
        var current = draft
        if let acknowledged = synchronization.receipts[draft.id]?.entry.version {
            current.expectedVersion = max(current.expectedVersion, acknowledged)
        }
        try storage.save(current)
        synchronization.edited(current)
        refreshDrafts()
    }

    func synchronizeDrafts() async {
        guard drafts.contains(where: { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        await synchronization.synchronize(excluding: busyEntryIDs)
        applyReceipts(newerThan: acceptedVersions)
        refreshDrafts()
    }

    private func applyReceipts(newerThan versions: [String: Int]) {
        for receipt in synchronization.receipts.values where receipt.entry.version > versions[receipt.entry.id, default: 0] {
            accept(receipt.entry)
        }
    }

    func accept(_ entry: JournalEntry) {
        guard entry.rootEntryId == nil else { return }
        if let current = entries.first(where: { $0.id == entry.id }), current.version > entry.version { return }
        acceptedVersions[entry.id] = max(acceptedVersions[entry.id, default: 0], entry.version)
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
        await synchronization.wait(for: id)
        if let receipt = synchronization.receipts[id] { accept(receipt.entry) }
        if let entry = entries.first(where: { $0.id == id }) {
            try await service.delete(id: id, version: entry.version)
        } else if let draft = try storage.load(id: id), draft.expectedVersion > 0 {
            try await service.delete(id: id, version: draft.expectedVersion)
        }
        entries.removeAll { $0.id == id }
        do {
            try discardDeviceCopies(id: id)
        } catch {
            throw APIClientError.rejected(status: 503, message: "Online deletion succeeded, but the device copy could not be removed. Retry to clear it.")
        }
        refreshDrafts()
    }

    private func discardDeviceCopies(id: String) throws {
        try synchronization.clear(id)
        try storage.discardAnswers(id: id)
        for child in try storage.list().drafts where child.rootEntryId == id { try storage.discard(child) }
        if let draft = try storage.load(id: id) { try storage.discard(draft) }
    }
}
