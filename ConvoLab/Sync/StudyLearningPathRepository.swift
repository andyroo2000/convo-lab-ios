import Foundation

struct StudyLearningPathRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func learningPath(for cardID: String) async throws -> StudyLearningPath {
        let response: APIEnvelope<StudyLearningPath> = try await api.request(
            "/api/cards/\(cardID)/learning-path"
        )
        return response.data
    }

    func linkSuccessor(
        _ successorID: String,
        to cardID: String,
        requirement: StudyLearningPathUnlockRequirement
    ) async throws -> StudyLearningPath {
        let response: APIEnvelope<StudyLearningPath> = try await api.request(
            "/api/cards/\(cardID)/learning-path/successor",
            method: "PUT",
            body: LinkStudyLearningPathSuccessorRequest(
                successorCardId: successorID,
                unlockRequirement: requirement
            )
        )
        return response.data
    }
}
