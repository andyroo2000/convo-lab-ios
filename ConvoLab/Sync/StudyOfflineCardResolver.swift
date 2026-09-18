import Foundation

@MainActor
struct StudyOfflineCardResolver {
    static let individualConcurrency = 4

    struct IndividualResult: Sendable {
        let index: Int
        let result: Result<StudyCard?, Error>
    }

    let api: APIClient

    func fetchBatch(_ cards: [StudyCard]) async throws -> StudyCardLookup {
        let ids = cards.map(\.reviewCardID).filter(ClientIdentifier.isULID)
        guard !ids.isEmpty else { return StudyCardLookup(preferred: [], fallback: []) }
        let response: StudyCardBatchResponse = try await api.request(
            "/api/study/cards/batch", method: "POST", body: StudyCardBatchRequest(ids: ids)
        )
        return StudyCardLookup(preferred: response.cards, fallback: [])
    }

    // Callers submit a window of at most individualConcurrency cards. Waiting for
    // each window keeps memory/network use bounded and enables grouped publication.
    func fetchIndividually(_ cards: [StudyCard]) async -> [IndividualResult] {
        precondition(cards.count <= Self.individualConcurrency)
        return await withTaskGroup(of: IndividualResult.self) { group in
            for (index, card) in cards.enumerated() {
                group.addTask { await resolve(card, index: index) }
            }
            var results: [IndividualResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func resolve(_ card: StudyCard, index: Int) async -> IndividualResult {
        do {
            try Task.checkCancellation()
            return IndividualResult(index: index, result: .success(try await fetch(card)))
        } catch {
            return IndividualResult(index: index, result: .failure(error))
        }
    }

    func fetch(_ card: StudyCard) async throws -> StudyCard? {
        do {
            let serverCard: StudyCard = try await api.request(
                "/api/study/cards/\(card.reviewCardID)"
            )
            guard StudyCardIdentity.matches(serverCard, card) else {
                throw APIClientError.invalidResponse
            }
            return serverCard
        } catch APIClientError.rejected(status: 404, message: _) {
            return nil
        }
    }
}
