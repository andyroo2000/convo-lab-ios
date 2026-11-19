import Foundation

@MainActor
@Observable
final class JournalTutorModel {
    let service: JournalService
    let entryID: String
    let input: JournalQuestionInput?
    private let savedQuestionID: String?
    private(set) var question: JournalTutorQuestion?
    private(set) var preferences: JournalTutorPreferences?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    var choosing = false
    private var refreshRequested = false
    private var catalogLoadedAt: Date?
    private let catalogLifetime: TimeInterval
    private var catalogTask: Task<JournalTutorPreferences, Error>?

    init(entry: JournalEntryModel, analysis: JournalAnalysis, savedQuestion: JournalTutorQuestion? = nil, catalogLifetime: TimeInterval = 60) {
        self.catalogLifetime = catalogLifetime
        savedQuestionID = savedQuestion?.id
        question = savedQuestion
        service = entry.store.service
        entryID = entry.id
        input = JournalQuestionInput(analysisId: analysis.id, replyId: analysis.currentReply?.id)
    }

    init(entryID: String, service: JournalService, savedQuestion: JournalTutorQuestion, catalogLifetime: TimeInterval = 60) {
        self.catalogLifetime = catalogLifetime
        self.entryID = entryID; self.service = service
        question = savedQuestion; savedQuestionID = savedQuestion.id; input = nil
    }

    func load() async {
        await perform {
            self.question = try await self.prepare()
            if self.question?.tutor == nil { try await self.openPicker() }
            else { self.choosing = false }
        }
        if question?.tutor != nil { await preloadAvatars() }
    }

    func refreshUnassignedTutor() async {
        guard question?.tutor == nil else { return }
        refreshRequested = true
        guard !isBusy else { return }
        refreshRequested = false
        await load()
    }

    func showPicker() async { await perform { try await self.openPicker() } }

    func choose(_ tutor: JournalTutor) async {
        await perform {
            self.preferences = try await self.service.chooseTutor(tutor.id)
            self.catalogLoadedAt = Date()
            self.question = try await self.prepare()
            self.choosing = false
        }
    }

    func monitorAudio() async {
        guard let questionID = question?.id else { return }
        do {
            while question?.audio?.waiting == true {
                try await Task.sleep(for: .seconds(2))
                let updated = try await service.question(entryID: entryID, questionID: questionID)
                guard question?.id == questionID else { return }
                question = updated
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = "Question audio status is unavailable. Please retry." } }
    }

    private func prepare() async throws -> JournalTutorQuestion {
        if let savedQuestionID { return try await service.retryQuestion(entryID: entryID, questionID: savedQuestionID) }
        guard let input else { throw APIClientError.invalidResponse }
        return try await service.prepareQuestion(entryID: entryID, input: input)
    }

    private func openPicker() async throws {
        try await loadPreferences()
        JournalAvatarCache.shared.preload(preferences?.tutors.map(\.avatarUrl) ?? [])
        choosing = true
    }

    private func preloadAvatars() async {
        // An optional artwork fetch must never turn a usable question into an error.
        try? await loadPreferences()
        JournalAvatarCache.shared.preload(preferences?.tutors.map(\.avatarUrl) ?? [])
    }

    private func loadPreferences() async throws {
        if let catalogLoadedAt, Date().timeIntervalSince(catalogLoadedAt) >= 0,
           Date().timeIntervalSince(catalogLoadedAt) < catalogLifetime { return }
        if catalogTask == nil { catalogTask = Task { try await service.tutorPreferences() } }
        defer { catalogTask = nil }
        let catalog = try await catalogTask?.value
        try Task.checkCancellation()
        // Reuse a recent backend snapshot; later openings refresh server-side changes.
        preferences = catalog
        catalogLoadedAt = Date()
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        do { try await operation() }
        catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = "Your tutor could not be loaded or saved. Please try again." } }
        isBusy = false
        if refreshRequested {
            refreshRequested = false
            if !Task.isCancelled { await refreshUnassignedTutor() }
        }
    }
}
