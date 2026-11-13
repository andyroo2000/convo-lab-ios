import Foundation

nonisolated struct JournalVersionPayload: Encodable, Sendable { let expectedVersion: Int }
nonisolated struct JournalRevisionPayload: Encodable, Sendable {
    let analysisId: String
    let expectedRevision: Int
}
nonisolated struct JournalAnswerPayload: Codable, Sendable {
    let analysisId: String
    let answer: String
    let expectedRevision: Int
    let replace: Bool
}
nonisolated struct JournalAudioPayload: Encodable, Sendable {
    let analysisId: String
    let voiceId: String
    let expectedReplyRevision: Int
}

nonisolated struct JournalSuggestionPayload: Encodable, Sendable {
    let analysisId: String
    let expectedRevision: Int
    let suggestionId: String
    let applied: Bool
}
nonisolated struct JournalCorrectedPayload: Encodable, Sendable {
    let analysisId: String
    let expectedRevision: Int
    let text: String
}

@MainActor
struct JournalService {
    private let api: APIClient
    private let token: String?

    init(api: APIClient) { self.api = api; token = api.accessToken }

    func checkSession() throws {
        guard token != nil, api.accessToken == token else {
            throw APIClientError.rejected(status: 401, message: "Your session changed. Reopen Journal to continue.")
        }
        try Task.checkCancellation()
    }

    func archive(cursor: String? = nil) async throws -> JournalArchivePage {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
        return try await request("/api/journal/entries", query: query)
    }

    func entry(_ id: String) async throws -> JournalEntry {
        let value: JournalResource<JournalEntry> = try await request(path(id))
        return value.data
    }

    func save(_ draft: JournalDraft) async throws -> JournalEntry {
        let body = JournalSavePayload(title: draft.title, body: draft.body, entryDate: draft.entryDate, expectedVersion: draft.expectedVersion)
        let value: JournalResource<JournalEntry> = try await request(path(draft.id), method: "PUT", body: body)
        return value.data
    }

    func submit(_ entry: JournalEntry) async throws -> JournalAnalysis {
        let value: JournalResource<JournalAnalysis> = try await request(path(entry.id) + "/submit", method: "POST", body: JournalVersionPayload(expectedVersion: entry.version))
        return value.data
    }

    func analysis(_ id: String) async throws -> JournalAnalysisResponse {
        try await request(path(id) + "/analysis")
    }

    func delete(id: String, version: Int) async throws {
        try checkSession()
        try await api.request(path(id), method: "DELETE", body: JournalVersionPayload(expectedVersion: version), authorizationToken: token)
        try checkSession()
    }

    func answer(entryID: String, replyID: String, body: JournalAnswerPayload) async throws -> JournalReply {
        let value: JournalResource<JournalReply> = try await request(replyPath(entryID, replyID), method: "PUT", body: body)
        return value.data
    }

    func reply(entryID: String, replyID: String) async throws -> JournalReply {
        let value: JournalResource<JournalReply> = try await request(replyPath(entryID, replyID))
        return value.data
    }

    func undo(entryID: String, body: JournalRevisionPayload) async throws -> JournalAnalysis {
        let value: JournalResource<JournalAnalysis> = try await request(path(entryID) + "/undo", method: "POST", body: body)
        return value.data
    }

    func suggestion(entryID: String, body: JournalSuggestionPayload) async throws -> JournalAnalysis {
        let value: JournalResource<JournalAnalysis> = try await request(path(entryID) + "/suggestion", method: "PUT", body: body)
        return value.data
    }

    func corrected(entryID: String, body: JournalCorrectedPayload) async throws -> JournalAnalysis {
        let value: JournalResource<JournalAnalysis> = try await request(path(entryID) + "/corrected", method: "PUT", body: body)
        return value.data
    }

    func tutorPreferences() async throws -> JournalTutorPreferences {
        let value: JournalResource<JournalTutorPreferences> = try await request("/api/journal/tutor")
        return value.data
    }

    func chooseTutor(_ id: String) async throws -> JournalTutorPreferences {
        let value: JournalResource<JournalTutorPreferences> = try await request("/api/journal/tutor", method: "PUT", body: JournalTutorChoice(tutorId: id))
        return value.data
    }

    func prepareQuestion(entryID: String, input: JournalQuestionInput) async throws -> JournalTutorQuestion {
        let value: JournalResource<JournalTutorQuestion> = try await request(path(entryID) + "/question", method: "POST", body: input)
        return value.data
    }

    func voices() async throws -> [JournalVoice] {
        let value: JournalResource<[JournalVoice]> = try await request("/api/journal/voices")
        return value.data
    }

    func audio(entryID: String, body: JournalAudioPayload) async throws -> Data {
        try checkSession()
        let data = try await api.journalAudio(entryID: entryID, body: body, authorizationToken: token)
        try checkSession()
        return data
    }

    func audioState(entryID: String, analysisID: String, revision: Int) async throws -> JournalAudioState {
        let query = [URLQueryItem(name: "analysisId", value: analysisID), URLQueryItem(name: "expectedReplyRevision", value: String(revision))]
        let value: JournalResource<JournalAudioState> = try await request(path(entryID) + "/audio", query: query)
        return value.data
    }

    private func request<Value: Decodable & Sendable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: (any Encodable)? = nil) async throws -> Value {
        try checkSession()
        let result: Value = try await api.request(path, method: method, query: query, body: body, authorizationToken: token)
        try checkSession()
        return result
    }

    private func path(_ id: String) throws -> String {
        guard ClientIdentifier.isULID(id) else { throw APIClientError.invalidResponse }
        return "/api/journal/entries/" + id.lowercased()
    }

    private func replyPath(_ entryID: String, _ replyID: String) throws -> String {
        guard ClientIdentifier.isULID(replyID) else { throw APIClientError.invalidResponse }
        return try path(entryID) + "/replies/" + replyID.lowercased()
    }
}
