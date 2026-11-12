import Foundation

@Observable
final class JournalEntryModel {
    nonisolated deinit {}
    let id: String
    let store: JournalStore
    var draft: JournalDraft?
    var analysis: JournalAnalysis?
    var isEditing = false
    private(set) var isBusy = false
    var errorMessage: String?
    var hasConflict = false
    var isSavedOnDevice = false

    init(id: String, store: JournalStore) { self.id = id; self.store = store }

    func load() async {
        do {
            try store.service.checkSession()
            if let local = try store.storage.load(id: id) {
                draft = local
                isSavedOnDevice = true
                isEditing = true
                return
            }
            draft = JournalDraft(entry: try await store.service.entry(id))
            try await refreshAnalysis()
        } catch { errorMessage = error.localizedDescription }
    }

    func change(_ edit: (inout JournalDraft) -> Void) {
        guard var updated = draft, !isBusy else { return }
        edit(&updated)
        updated.editID = UUID().uuidString
        draft = updated
        do {
            try store.write(updated)
            isSavedOnDevice = true
            errorMessage = nil
        } catch {
            isSavedOnDevice = false
            errorMessage = "Could not save this writing on your device. Keep the entry open."
        }
    }

    func save(submit: Bool) async {
        guard let sent = draft, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let entry = try await store.service.save(sent)
            try store.storage.acknowledge(sent, version: entry.version)
            store.accept(entry)
            store.refreshDrafts()
            draft = JournalDraft(entry: entry)
            isSavedOnDevice = false
            hasConflict = false
            if submit { try await submitSaved(entry) }
        } catch {
            hasConflict = Self.isConflict(error)
            errorMessage = error.localizedDescription
        }
    }

    private func submitSaved(_ entry: JournalEntry) async throws {
        do {
            analysis = try await store.service.submit(entry)
            isEditing = false
        } catch {
            errorMessage = "Saved, but feedback could not be requested. Try Submit again."
            throw APIClientError.rejected(status: 503, message: "Saved, but feedback could not be requested. Try Submit again.")
        }
    }

    func refreshAnalysis() async throws {
        let response = try await store.service.analysis(id)
        guard response.entry.body == draft?.body else { return }
        analysis = response.data
        // A generated title must never overwrite an unacknowledged edit.
        if try store.storage.load(id: id) == nil {
            draft = JournalDraft(entry: response.entry)
            store.accept(response.entry)
        }
    }

    func poll() async {
        do {
            while analysis?.status.isPending == true || analysis?.pendingReplyId != nil {
                try await Task.sleep(for: .seconds(2))
                try await refreshAnalysis()
            }
        } catch is CancellationError { }
        catch { errorMessage = "Could not check feedback. Reopen the entry when connected." }
    }

    func copyAsNew() throws -> String {
        guard let draft else { throw APIClientError.invalidResponse }
        var copy = JournalDraft.new()
        copy.title = draft.title
        copy.body = draft.body
        copy.entryDate = draft.entryDate
        try store.write(copy)
        return copy.id
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case APIClientError.rejected(status: 409, message: _) = error { return true }
        return false
    }
}
