import Foundation

@MainActor
@Observable
final class JournalEntryModel {
    nonisolated deinit {}
    let id: String
    let clarification: JournalClarificationModel
    let store: JournalStore
    private var initial: JournalConversationNode?
    private var initialDraft: JournalDraft?
    var draft: JournalDraft?
    var analysis: JournalAnalysis?
    var isEditing = false
    private(set) var isSubmitting = false
    private(set) var missingEntry = false
    private(set) var isBusy = false
    var errorMessage: String?
    var hasConflict = false
    var isSavedOnDevice = false

    init(id: String, store: JournalStore, initial: JournalConversationNode? = nil, initialDraft: JournalDraft? = nil) {
        clarification = JournalClarificationModel(service: store.service)
        self.id = id; self.store = store; self.initial = initial
        self.initialDraft = initialDraft
    }

    func load(snapshot: JournalConversationNode? = nil) async {
        guard snapshot == nil || (!isBusy && !isEditing) else { return }
        missingEntry = false
        do {
            try store.service.checkSession()
            let seed = snapshot ?? initial
            initial = nil
            if try restoreDraft() { return }
            if let seed {
                draft = JournalDraft(entry: seed.entry)
                analysis = seed.analysis
                return
            }
            draft = JournalDraft(entry: try await store.service.entry(id))
            try await refreshAnalysis()
        } catch {
            if draft == nil, case APIClientError.rejected(status: 404, message: _) = error { missingEntry = true }
            else { errorMessage = error.localizedDescription }
        }
    }

    private func restoreDraft() throws -> Bool {
        let local = try store.storage.load(id: id)
        guard let restored = local ?? initialDraft else { return false }
        draft = restored
        initialDraft = nil
        isSavedOnDevice = local != nil
        isEditing = true
        return true
    }

    var isUnwritten: Bool { draft.map(isUnwritten) ?? false }

    private func isUnwritten(_ draft: JournalDraft) -> Bool {
        !isSavedOnDevice && draft.expectedVersion == 0 && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func change(_ edit: (inout JournalDraft) -> Void) {
        guard var updated = draft, !isBusy, !store.busyEntryIDs.contains(id) else { return }
        if isUnwritten(updated) { updated.entryDate = JournalDates.storage.string(from: .now) }
        edit(&updated)
        updated.editID = UUID().uuidString
        draft = updated
        if isUnwritten(updated) { return }
        do {
            try store.write(updated)
            isSavedOnDevice = true
            errorMessage = nil
        } catch {
            isSavedOnDevice = false
            errorMessage = "Could not save this writing on your device. Keep the entry open."
        }
    }

    @discardableResult
    func save(submit: Bool) async -> Bool {
        guard let sent = draft, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try store.beginMutation(id: id)
            defer { store.endMutation(id: id) }
            let entry = try await store.service.save(sent)
            try store.storage.acknowledge(sent, version: entry.version)
            store.accept(entry)
            store.refreshDrafts()
            draft = JournalDraft(entry: entry)
            isSavedOnDevice = false
            hasConflict = false
            if submit { await submitSaved(entry) }
            return true
        } catch {
            hasConflict = Self.isConflict(error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func submitSaved(_ entry: JournalEntry) async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            guard let clarificationID = await clarification.begin(entry) else { return }
            analysis = try await store.service.submit(entry, clarificationID: clarificationID)
            UserDefaults.standard.set(JournalVersion.draft.rawValue, forKey: JournalVersion.preferenceKey(owner: store.storage.directory.lastPathComponent, entry: id))
            isEditing = false
        } catch {
            hasConflict = Self.isConflict(error)
            errorMessage = "Saved, but feedback could not be requested. Try Submit again."
        }
    }

    func refreshAnalysis() async throws {
        let response = try await store.service.analysis(id)
        let local = try store.storage.load(id: id)
        if local != nil && response.entry.body != draft?.body {
            analysis = nil
            return
        }
        guard response.entry.body == draft?.body else {
            analysis = nil
            hasConflict = true
            throw APIClientError.rejected(status: 409, message: "This entry changed on another device. Your writing is still here; save it as a new entry.")
        }
        analysis = response.data
        // A generated title must never overwrite an unacknowledged edit.
        if local == nil {
            draft = JournalDraft(entry: response.entry)
            store.accept(response.entry)
        }
    }

    func poll() async {
        var failures = 0
        while analysis?.status.isPending == true || analysis?.pendingReplyId != nil {
            do {
                try await Task.sleep(for: .seconds(2 * (failures + 1)))
                try await refreshAnalysis()
                failures = 0
            } catch is CancellationError { return }
            catch {
                failures += 1
                if Self.endsPolling(error) || failures >= 3 {
                    errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    private static func endsPolling(_ error: Error) -> Bool {
        if case APIClientError.rejected(let status, _) = error { return status == 401 || status == 409 }
        return false
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
