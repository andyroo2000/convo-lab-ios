import Foundation

extension JournalStore {
    func rename(_ entry: JournalDraft, title input: String) async throws {
        try service.checkSession()
        let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.unicodeScalars.count <= 255 else {
            throw APIClientError.rejected(status: 422, message: "Enter a title of 1–255 characters.")
        }
        let local = try storage.load(id: entry.id)
        if entry.expectedVersion == 0, var draft = local, draft.expectedVersion == 0 {
            draft.title = title
            draft.editID = UUID().uuidString
            try write(draft)
            return
        }
        let server = try await service.entry(entry.id)
        guard server.version == entry.expectedVersion || server.title == title else {
            throw APIClientError.rejected(status: 409, message: "This entry changed elsewhere. Refresh the journal and try again.")
        }
        // Rename the saved entry without publishing any unsaved writing.
        var request = JournalDraft(entry: server)
        request.title = title
        let saved = server.title == title ? server : try await service.save(request)
        accept(saved)
        do {
            try reconcileTitle(entry, previousTitle: local?.title, saved: saved)
        } catch {
            throw APIClientError.rejected(status: 503, message: "The title was saved online, but the device draft could not be updated. Try Save again.")
        }
        refreshDrafts()
    }

    private func reconcileTitle(_ entry: JournalDraft, previousTitle: String?, saved: JournalEntry) throws {
        guard var current = try storage.load(id: entry.id) else { return }
        if current.title == previousTitle { current.title = saved.title }
        if current.expectedVersion == entry.expectedVersion && saved.version <= entry.expectedVersion + 1 {
            current.expectedVersion = saved.version
        }
        current.editID = UUID().uuidString
        try storage.save(current)
    }
}
