import Foundation

extension StudyStore {
    func canEditCardPlacement(id: String) -> Bool {
        ClientIdentifier.isULID(id) && (try? cardOutbox.hasPendingCardWrite(for: id)) == false
    }

    func cardPlacement(id: String) async throws -> StudyCardPlacementSnapshot {
        guard let userID = activeUserID else { throw CancellationError() }
        let generation = accountActivationGeneration
        guard canEditCardPlacement(id: id) else {
            throw APIClientError.rejected(status: 409, message: "Sync pending card changes before editing its source or priority.")
        }
        let snapshot: StudyCardPlacementSnapshot = try await api.request("/api/study/cards/\(id.lowercased())")
        guard isCurrentActivation(userID, generation: generation) else { throw CancellationError() }
        return snapshot
    }

    func assignCardSource(id: String, source: StudyBookSource?) async throws {
        try await updateCardPlacement(path: "/card-sources", id: id,
                                      body: StudyCardSourceAssignment(cardIds: [id], bookSource: source))
    }

    func assignLearnSoon(id: String, value: Bool) async throws {
        try await updateCardPlacement(path: "/learn-soon", id: id,
                                      body: StudyLearnSoonAssignment(cardIds: [id], learnSoon: value))
    }

    private func updateCardPlacement(path: String, id: String, body: any Encodable) async throws {
        guard let userID = activeUserID, let token = api.accessToken else { throw CancellationError() }
        guard canEditCardPlacement(id: id) else {
            throw APIClientError.rejected(status: 409, message: "Sync pending card changes before editing its source or priority.")
        }
        let generation = accountActivationGeneration
        try await api.request("/api/study\(path)", method: "PUT", body: body, authorizationToken: token)
        guard isCurrentActivation(userID, generation: generation) else { throw CancellationError() }
        await synchronize()
        await refreshPiles()
    }
}
