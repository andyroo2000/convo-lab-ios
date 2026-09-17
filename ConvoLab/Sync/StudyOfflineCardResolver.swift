import Foundation

struct StudyOfflineCardResolver {
    let api: APIClient

    func fetchBatch(_ cards: [StudyCard]) async throws -> StudyCardLookup {
        let ids = cards.map(\.reviewCardID).filter(ClientIdentifier.isULID)
        guard !ids.isEmpty else { return StudyCardLookup(preferred: [], fallback: []) }
        let response: StudyCardBatchResponse = try await api.request(
            "/api/study/cards/batch", method: "POST", body: StudyCardBatchRequest(ids: ids)
        )
        return StudyCardLookup(preferred: response.cards, fallback: [])
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
