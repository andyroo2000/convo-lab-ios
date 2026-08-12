import Foundation

@MainActor
struct StudyPublishedCardReconciler {
    private typealias RestoredCard = CardSyncFeedRepository.CommittedPageChanges.RestoredCard

    private struct PrunedCard {
        let index: Int
        let card: StudyCard
    }

    private var prunedCards: [PrunedCard] = []

    mutating func apply(
        _ changes: CardSyncFeedRepository.CommittedPageChanges,
        to publishedCards: inout [StudyCard]
    ) {
        for (index, card) in publishedCards.enumerated()
        where Self.matches(card, identifiers: changes.deletedCardIdentifiers) {
            prunedCards.append(PrunedCard(index: index, card: card))
        }
        publishedCards.removeAll {
            Self.matches($0, identifiers: changes.deletedCardIdentifiers)
        }

        let restoring: [(item: PrunedCard, restored: RestoredCard)] = prunedCards.compactMap {
            item -> (item: PrunedCard, restored: RestoredCard)? in
            guard let restored = changes.restoredCards.last(where: {
                Self.matches(item.card, identifiers: $0.identifiers)
            }) else { return nil }
            return (item: item, restored: restored)
        }
            .sorted { $0.item.index < $1.item.index }
        for restoration in restoring {
            if let existingIndex = publishedCards.firstIndex(where: {
                Self.representsSameCard($0, as: restoration.restored)
            }) {
                publishedCards[existingIndex] = restoration.restored.card
            } else {
                publishedCards.insert(
                    restoration.restored.card,
                    at: min(restoration.item.index, publishedCards.count)
                )
            }
        }
        prunedCards.removeAll { item in
            changes.restoredCards.contains(where: { restored in
                Self.matches(item.card, identifiers: restored.identifiers)
            })
        }
    }

    static func prune(
        _ publishedCards: inout [StudyCard],
        matching identifiers: Set<String>
    ) {
        publishedCards.removeAll {
            matches($0, identifiers: identifiers)
        }
    }

    private static func matches(_ card: StudyCard, identifiers: Set<String>) -> Bool {
        StudyCardIdentity.matches(card, any: identifiers)
    }

    private static func representsSameCard(
        _ card: StudyCard,
        as restored: RestoredCard
    ) -> Bool {
        StudyCardIdentity.matches(card, restored.card)
            || StudyCardIdentity.matches(card, any: restored.identifiers)
    }
}
