import Foundation

@MainActor
@Observable
final class JournalReplyModel {
    nonisolated deinit {}
    let entry: JournalEntryModel
    private let storage: JournalAnswerStorage
    private(set) var draft = JournalAnswerDraft()
    private(set) var isBusy = false
    private var replyStatus: JournalAnalysisStatus?
    private var missing = false
    var errorMessage: String?

    init(entry: JournalEntryModel, storage: JournalAnswerStorage) {
        self.entry = entry
        self.storage = storage
        do { draft = try storage.load(); reconcile() }
        catch { errorMessage = "This device answer could not be opened. Its file will be preserved before you write a replacement." }
    }
    var pendingID: String? { entry.analysis?.pendingReplyId ?? draft.request?.id }
    var processing: Bool { entry.analysis?.pendingReplyId != nil || replyStatus?.isPending == true }
    var waiting: Bool { processing || (draft.request != nil && replyStatus != .failed && !missing) }

    func change(_ text: String) {
        guard !isBusy && !waiting else { return }
        persist(JournalAnswerDraft(answer: text, replace: draft.replace))
    }
    func editLast() {
        guard !isBusy && !waiting, let answer = entry.analysis?.currentReply?.answer else { return }
        persist(JournalAnswerDraft(answer: answer, replace: true))
    }
    func cancelEdit() {
        guard !isBusy && !waiting else { return }
        persist(JournalAnswerDraft())
    }
    @discardableResult
    private func persist(_ value: JournalAnswerDraft) -> Bool {
        draft = value
        do { try entry.store.service.checkSession(); try storage.save(value); return true }
        catch { errorMessage = "Could not save this answer on your device. Keep the entry open."; return false }
    }

    func submit() async {
        guard !isBusy && !processing, let analysis = entry.analysis,
              !draft.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let request = draft.request ?? JournalAnswerRequest(id: ClientIdentifier.ulid().lowercased(),
            payload: JournalAnswerPayload(analysisId: analysis.id, answer: draft.answer,
                                          expectedRevision: analysis.replyRevision ?? 0, replace: draft.replace))
        guard persist(JournalAnswerDraft(answer: draft.answer, replace: draft.replace, request: request)) else { return }
        isBusy = true
        missing = false
        errorMessage = nil
        defer { isBusy = false }
        do {
            let reply = try await entry.store.service.answer(entryID: entry.id, replyID: request.id, body: request.payload)
            replyStatus = reply.status
            try await entry.refreshAnalysis()
            reconcile()
        } catch {
            try? await entry.refreshAnalysis()
            reconcile()
            errorMessage = "Could not add this answer. Your writing is kept here; try again."
        }
    }

    func monitor() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(min(30, 2 * (failures + 1))))
                try await checkPending()
                failures = 0
            } catch is CancellationError { return }
            catch {
                failures += 1
                errorMessage = "Could not check this answer. Your writing is kept here; retrying when connected."
            }
        }
    }

    func checkPending() async throws {
        guard let id = pendingID else { return }
        if entry.analysis?.pendingReplyId == nil {
            if missing || replyStatus == .failed { return }
        }
        do {
            let reply = try await entry.store.service.reply(entryID: entry.id, replyID: id)
            guard pendingID == id else { return }
            replyStatus = reply.status
            if !reply.status.isPending {
                try await entry.refreshAnalysis()
                reconcile()
                errorMessage = reply.error
            }
        } catch APIClientError.rejected(status: 404, message: _) {
            missing = true
            replyStatus = nil
        }
    }

    func reconcile() {
        guard let request = draft.request, let analysis = entry.analysis else { return }
        if analysis.currentReply?.id == request.id {
            draft = JournalAnswerDraft()
            replyStatus = nil
            do { try storage.clear() }
            catch { errorMessage = "Answer added. Its device copy could not be cleared." }
        } else if (analysis.replyRevision ?? 0) != request.payload.expectedRevision {
            persist(JournalAnswerDraft(answer: draft.answer))
            replyStatus = nil
            errorMessage = "The entry changed. Review your answer before adding it again."
        }
    }

    func undo() async {
        guard !isBusy && !waiting, let analysis = entry.analysis else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            entry.analysis = try await entry.store.service.undo(entryID: entry.id,
                body: JournalRevisionPayload(analysisId: analysis.id, expectedRevision: analysis.replyRevision ?? 0))
            reconcile()
        } catch {
            try? await entry.refreshAnalysis()
            reconcile()
            errorMessage = "Could not confirm undo. Check the current entry before trying again."
        }
    }
}
