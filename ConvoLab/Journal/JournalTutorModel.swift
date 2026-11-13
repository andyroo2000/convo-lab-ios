import Foundation

@MainActor
@Observable
final class JournalTutorModel {
    let service: JournalService
    let entryID: String
    let input: JournalQuestionInput
    private(set) var question: JournalTutorQuestion?
    private(set) var preferences: JournalTutorPreferences?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    var choosing = false

    init(entry: JournalEntryModel, analysis: JournalAnalysis) {
        service = entry.store.service
        entryID = entry.id
        input = JournalQuestionInput(analysisId: analysis.id, replyId: analysis.currentReply?.id)
    }

    func load() async {
        await perform {
            self.question = try await self.service.prepareQuestion(entryID: self.entryID, input: self.input)
            if self.question?.tutor == nil { try await self.openPicker() }
        }
    }

    func showPicker() async { await perform { try await self.openPicker() } }

    func choose(_ tutor: JournalTutor) async {
        await perform {
            self.preferences = try await self.service.chooseTutor(tutor.id)
            self.choosing = false
            self.question = try await self.service.prepareQuestion(entryID: self.entryID, input: self.input)
        }
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
        catch { errorMessage = "Your tutor could not be loaded or saved. Please try again." }
    }
}
