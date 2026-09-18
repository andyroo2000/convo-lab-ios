import Foundation

struct StudyOfflineCardChanges {
    private let changesByIdentifier: [String: StudyOfflineCardReconciler.Change]

    init(_ changes: [StudyOfflineCardReconciler.Change]) {
        var indexed: [String: StudyOfflineCardReconciler.Change] = [:]
        for change in changes {
            for identifier in change.identifiers { indexed[identifier] = change }
        }
        changesByIdentifier = indexed
    }

    func applying(to cards: [StudyCard], studying: Bool = false) -> [StudyCard] {
        cards.compactMap { existing in
            guard let change = StudyCardIdentity.identifiers(for: existing).lazy.compactMap({
                changesByIdentifier[$0]
            }).first else { return existing }
            guard let card = change.card else { return nil }
            if studying && !card.isEligibleForOfflineStudy(at: change.evaluatedAt) { return nil }
            return card
        }
    }
}
