import Foundation

@MainActor
@Observable
final class JournalTutorModel {
    let service: JournalService
    let entryID: String
    let input: JournalQuestionInput
    private let savedQuestionID: String?
    private(set) var question: JournalTutorQuestion?
    private(set) var preferences: JournalTutorPreferences?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    var choosing = false

    init(entry: JournalEntryModel, analysis: JournalAnalysis, savedQuestion: JournalTutorQuestion? = nil) {
        savedQuestionID = savedQuestion?.id
        question = savedQuestion
        service = entry.store.service
        entryID = entry.id
        input = JournalQuestionInput(analysisId: analysis.id, replyId: analysis.currentReply?.id)
    }

    func load() async {
        await perform {
            self.question = try await self.prepare()
            if self.question?.tutor == nil { try await self.openPicker() }
        }
    }

    func showPicker() async { await perform { try await self.openPicker() } }

    func choose(_ tutor: JournalTutor) async {
        await perform {
            self.preferences = try await self.service.chooseTutor(tutor.id)
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
        return try await service.prepareQuestion(entryID: entryID, input: input)
    }

    private func openPicker() async throws {
        preferences = try await service.tutorPreferences()
        choosing = true
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = "Your tutor could not be loaded or saved. Please try again." } }
    }
}
