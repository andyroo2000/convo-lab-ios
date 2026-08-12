import Foundation

struct StudyCardCatalogRepository {
    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func newCardQueuePage(after cursor: String? = nil) async throws -> StudyNewCardQueueResponse {
        var query: [URLQueryItem] = []
        if let cursor {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        query.append(URLQueryItem(name: "limit", value: "100"))
        return try await api.request("/api/study/new-queue", query: query)
    }

    func cardPage(
        matching query: String,
        after cursor: String? = nil
    ) async throws -> StudyCardListResponse {
        var queryItems: [URLQueryItem] = []
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        queryItems.append(URLQueryItem(name: "per_page", value: "50"))
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        return try await api.request("/api/study/cards", query: queryItems)
    }

    func reorderNewCards(_ cardIDs: [String]) async throws -> StudyNewCardQueueResponse {
        try await api.request(
            "/api/study/new-queue/reorder",
            method: "POST",
            body: ReorderStudyNewCardQueueRequest(cardIds: cardIDs)
        )
    }

    static func appendingUniqueCards(
        _ incoming: [StudyCard],
        to existing: [StudyCard]
    ) -> [StudyCard] {
        var seenIdentifiers = existing.reduce(into: Set<String>()) {
            $0.formUnion(StudyCardIdentity.identifiers(for: $1))
        }
        return existing + incoming.filter { card in
            let identifiers = StudyCardIdentity.identifiers(for: card)
            guard seenIdentifiers.isDisjoint(with: identifiers) else { return false }
            seenIdentifiers.formUnion(identifiers)
            return true
        }
    }

    static func appendingUniqueQueueItems(
        _ incoming: [StudyNewCardQueueItem],
        to existing: [StudyNewCardQueueItem]
    ) -> [StudyNewCardQueueItem] {
        appendingUnique(incoming, to: existing, identifiedBy: \.id)
    }

    static func cards(_ cards: [StudyCard], matching query: String) -> [StudyCard] {
        cards.filter { matches($0, query: query) }
    }

    static func upserting(
        _ card: StudyCard,
        into cards: [StudyCard],
        matching query: String
    ) -> [StudyCard] {
        var result = cards.filter { !StudyCardIdentity.matches($0, card) }
        guard matches(card, query: query) else { return result }
        result.append(card)
        result.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id > $1.id
            }
            return $0.createdAt > $1.createdAt
        }
        return result
    }

    private static func appendingUnique<Item>(
        _ incoming: [Item],
        to existing: [Item],
        identifiedBy id: KeyPath<Item, String>
    ) -> [Item] {
        var seenIDs = Set(existing.map { $0[keyPath: id].lowercased() })
        return existing + incoming.filter {
            seenIDs.insert($0[keyPath: id].lowercased()).inserted
        }
    }

    private static func matches(_ card: StudyCard, query: String) -> Bool {
        query.isEmpty
            || card.promptText.localizedCaseInsensitiveContains(query)
            || card.answerText.localizedCaseInsensitiveContains(query)
    }
}
