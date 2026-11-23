import Foundation

/// Keeps the exact attempted payload durable until its acknowledgement is recorded.
@MainActor
@Observable
final class JournalDraftSync {
    nonisolated deinit {}
    struct Receipt { let sent: JournalDraft; let entry: JournalEntry }
    private let service: JournalService
    private let drafts: JournalDraftStorage
    private let checkpoints: JournalSyncStorage
    private var running: [String: Task<JournalEntry, Error>] = [:]
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Int] = [:]
    private(set) var receipts: [String: Receipt] = [:]
    private(set) var blocked: [String: Int] = [:]
    private(set) var revision = 0

    init(service: JournalService, drafts: JournalDraftStorage) {
        self.service = service; self.drafts = drafts
        checkpoints = JournalSyncStorage(drafts: drafts)
    }

    func edited(_ draft: JournalDraft) {
        do { try resetValidationRejection(draft) }
        catch { blocked[draft.id] = 503; revision += 1 }
    }

    private func resetValidationRejection(_ draft: JournalDraft) throws {
        let checkpoint = try checkpoints.load(draft.id)
        guard let status = checkpoint.rejection, [400, 422].contains(status),
              checkpoint.pending?.editID != draft.editID else { return }
        try checkpoints.remove(draft.id)
        blocked.removeValue(forKey: draft.id)
        retryAfter.removeValue(forKey: draft.id)
        revision += 1
    }

    func reconnect() { retryAfter.removeAll() }

    func isSyncing(_ id: String) -> Bool { running[id] != nil }

    func wait(for id: String) async { _ = try? await running[id]?.value }

    func settlePending(_ id: String) async throws {
        await wait(for: id)
        let checkpoint = try checkpointForSending(id)
        guard let pending = checkpoint.pending, checkpoint.rejection == nil else { return }
        _ = try await save(pending)
    }

    func save(_ draft: JournalDraft) async throws -> JournalEntry {
        if let task = running[draft.id] { return try await task.value }
        let task = Task { try await self.send(draft) }
        running[draft.id] = task
        defer { running[draft.id] = nil }
        return try await task.value
    }

    func saveLatest(_ draft: JournalDraft) async throws -> JournalEntry {
        var pending = draft
        for _ in 0..<3 {
            let entry = try await save(pending)
            guard let newer = try drafts.load(id: draft.id) else { return entry }
            pending = newer
        }
        throw JournalSyncStillChanging()
    }

    func synchronize(isBusy: (String) -> Bool) async {
        guard let listing = try? drafts.list() else { return }
        for draft in listing.drafts where draft.rootEntryId == nil {
            guard !Task.isCancelled else { return }
            guard !isBusy(draft.id), let local = try? drafts.load(id: draft.id) else { continue }
            guard retryAfter[draft.id, default: .distantPast] <= .now else { continue }
            guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                _ = try await save(local)
                failures[draft.id] = nil
                retryAfter[draft.id] = nil
            } catch {
                let count = min(failures[draft.id, default: 0] + 1, 5)
                failures[draft.id] = count
                retryAfter[draft.id] = Date.now.addingTimeInterval(min(60, pow(2, Double(count))))
            }
        }
    }

    func clear(_ id: String) throws {
        try checkpoints.remove(id)
        blocked.removeValue(forKey: id)
        receipts.removeValue(forKey: id)
        revision += 1
    }

    private func send(_ draft: JournalDraft) async throws -> JournalEntry {
        try service.checkSession()
        var checkpoint = try checkpointForSending(draft.id)
        if let status = checkpoint.rejection, status != 403 {
            blocked[draft.id] = status
            throw APIClientError.rejected(status: status, message: Self.message(status))
        }
        // An interrupted request is retried before sending any later keystrokes.
        let local = try drafts.load(id: draft.id)
        let sent = checkpoint.pending ?? local ?? draft
        checkpoint.pending = sent
        try checkpoints.save(checkpoint, id: draft.id)
        let entry: JournalEntry
        do { entry = try await service.save(sent) }
        catch {
            try recordRejection(error, checkpoint: checkpoint, id: draft.id)
            throw error
        }
        try drafts.acknowledge(sent, version: entry.version)
        try checkpoints.remove(draft.id)
        blocked.removeValue(forKey: draft.id)
        receipts[draft.id] = Receipt(sent: sent, entry: entry)
        revision += 1
        return entry
    }

    private func checkpointForSending(_ id: String) throws -> JournalSyncCheckpoint {
        do { return try checkpoints.load(id) }
        catch {
            blocked[id] = 503
            revision += 1
            throw APIClientError.rejected(status: 503, message: Self.message(503))
        }
    }

    private func recordRejection(_ error: Error, checkpoint: JournalSyncCheckpoint, id: String) throws {
        guard case APIClientError.rejected(let status, _) = error,
              [400, 403, 404, 409, 422].contains(status) else { return }
        var rejected = checkpoint
        rejected.rejection = status == 403 ? nil : status
        try checkpoints.save(rejected, id: id)
        blocked[id] = status
        revision += 1
    }

    static func message(_ status: Int) -> String {
        if status == 503 {
            return "Pending sync data could not be read. Your writing is saved on this device; save it as a new entry."
        }
        if status == 404 || status == 409 {
            return "This entry changed or was deleted elsewhere. Your writing is saved on this device; save it as a new entry."
        }
        return "This entry could not sync. Your writing is saved on this device."
    }
}

private struct JournalSyncStillChanging: LocalizedError {
    var errorDescription: String? { "Writing is still changing. It is kept on this device; try Save again." }
}
