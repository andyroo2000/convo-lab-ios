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
