import Foundation

nonisolated struct JournalClarification: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case queued, processing, waiting, resolved, failed
        var isPending: Bool { self == .queued || self == .processing }
    }
    struct Question: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let prompt: String
        let choices: [String]
    }
    let id: String
    let sourceVersion: Int
    let revision: Int
    let status: Status
    let question: Question?
    let error: String?
    let updatedAt: String
}
nonisolated struct JournalSubmissionPayload: Encodable, Sendable {
    let expectedVersion: Int
    let clarificationId: String?
}
nonisolated struct JournalClarificationAnswerPayload: Encodable, Sendable {
    let expectedVersion: Int
    let questionId: String
    let answer: String
}

extension JournalService {
    func startClarification(_ entry: JournalEntry) async throws -> JournalClarification {
        let value: JournalResource<JournalClarification> = try await request(path(entry.id) + "/clarification", method: "POST", body: JournalVersionPayload(expectedVersion: entry.version))
        return value.data
    }

    func clarification(_ entry: JournalEntry) async throws -> JournalClarification {
        let value: JournalResource<JournalClarification?> = try await request(path(entry.id) + "/clarification")
        guard let state = value.data else {
            throw APIClientError.rejected(status: 409, message: "The draft changed. Go back and submit it again.")
        }
        return state
    }

    func answerClarification(_ entry: JournalEntry, state: JournalClarification, answer: String) async throws -> JournalClarification {
        guard ClientIdentifier.isULID(state.id), let question = state.question else { throw APIClientError.invalidResponse }
        let body = JournalClarificationAnswerPayload(expectedVersion: entry.version, questionId: question.id, answer: answer)
        let value: JournalResource<JournalClarification> = try await request(path(entry.id) + "/clarification/" + state.id.lowercased() + "/answer", method: "POST", body: body)
        return value.data
    }
}
