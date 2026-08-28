import Foundation

enum StudyCardIdentity {
    static func identifiers(for card: StudyCard) -> Set<String> {
        normalized([card.id, card.reviewCardID])
    }

    static func matches(_ lhs: StudyCard, _ rhs: StudyCard) -> Bool {
        !identifiers(for: lhs).isDisjoint(with: identifiers(for: rhs))
    }

    static func matches(_ card: StudyCard, any identifiers: some Sequence<String>) -> Bool {
        !self.identifiers(for: card).isDisjoint(with: normalized(identifiers))
    }

    static func normalized(_ identifiers: some Sequence<String>) -> Set<String> {
        Set(identifiers.map { $0.lowercased() })
    }
}

struct StudyCardLookup {
    private let cardsByIdentifier: [String: StudyCard]

    init(preferred: [StudyCard], fallback: [StudyCard]) {
        var cardsByIdentifier: [String: StudyCard] = [:]
        // Match the former first(where:) behavior within each collection while
        // allowing the server presentation to override the local fallback.
        for card in fallback.reversed() {
            for identifier in StudyCardIdentity.identifiers(for: card) {
                cardsByIdentifier[identifier] = card
            }
        }
        for card in preferred.reversed() {
            for identifier in StudyCardIdentity.identifiers(for: card) {
                cardsByIdentifier[identifier] = card
            }
        }
        self.cardsByIdentifier = cardsByIdentifier
    }

    func card(matching identifiers: some Sequence<String>) -> StudyCard? {
        identifiers.lazy.compactMap {
            cardsByIdentifier[$0.lowercased()]
        }.first
    }
}
