import Foundation

enum StudySessionPolicy {
    static func orderedCards(_ cards: [StudyCard]) -> [StudyCard] {
        cards.enumerated().sorted { leftEntry, rightEntry in
            let left = leftEntry.element
            let right = rightEntry.element
            let leftIsNew = left.state.queueState == "new"
            let rightIsNew = right.state.queueState == "new"
            if leftIsNew != rightIsNew {
                return !leftIsNew
            }
            if leftIsNew {
                return leftEntry.offset < rightEntry.offset
            }
            let leftDueAt = left.state.dueAt ?? .distantFuture
            let rightDueAt = right.state.dueAt ?? .distantFuture
            if leftDueAt != rightDueAt {
                return leftDueAt < rightDueAt
            }
            if left.id != right.id {
                return left.id < right.id
            }
            return leftEntry.offset < rightEntry.offset
        }
        .map(\.element)
    }

    static func nextOfflineDueAt(
        activeCards: [StudyCard],
        libraryCards: [StudyCard],
        at date: Date = .now
    ) -> Date? {
        let activeCardIDs = Set(activeCards.map(\.id))
        return libraryCards.compactMap { card in
            guard !activeCardIDs.contains(card.id) else { return nil }
            guard ["learning", "review", "relearning"].contains(card.state.queueState) else {
                return nil
            }
            return card.state.dueAt
        }
        .filter { $0 > date }
        .min()
    }
}

struct StudySessionCounts: Equatable {
    let failedDue: Int
    let reviewRemaining: Int
    let newRemaining: Int

    var hasRemainingReviews: Bool {
        failedDue > 0 || reviewRemaining > 0
    }

    var hasRemainingStudy: Bool {
        hasRemainingReviews || newRemaining > 0
    }

    func offlineReadinessTarget(
        loadedCardCount: Int,
        fiveDayNewCardTarget: Int
    ) -> Int {
        max(
            loadedCardCount,
            failedDue + reviewRemaining,
            fiveDayNewCardTarget
        )
    }

    static func calculate(
        cards: [StudyCard],
        overview: StudyOverview?,
        retainedFailedCardIDs: Set<String> = [],
        resolvedFailedCardIDs: Set<String> = [],
        at date: Date = .now
    ) -> StudySessionCounts {
        let loadedFailedDueCardIDs = Set(
            cards.lazy.filter {
                $0.state.failedAt != nil
                    && ($0.state.dueAt.map { $0 <= date } ?? true)
            }.map(\.id)
        )
        let pendingReviewedFailedCardIDs = retainedFailedCardIDs
            .union(resolvedFailedCardIDs)
        let authoritativeFailedDueCount = max(
            0,
            (overview?.failedDueCount ?? overview?.failedCount ?? 0)
                - pendingReviewedFailedCardIDs.count
        )
        let loadedNewRemaining = cards.count(where: {
            $0.state.failedAt == nil && $0.state.queueState == "new"
        })
        let newRemaining = overview?.newCount
            ?? loadedNewRemaining
        let loadedReviewRemaining = cards.count(where: {
            $0.state.failedAt == nil && $0.state.queueState != "new"
        })
        let reviewRemaining = overview.map { max(0, $0.dueCount) }
            ?? loadedReviewRemaining

        return StudySessionCounts(
            failedDue: max(authoritativeFailedDueCount, loadedFailedDueCardIDs.count),
            reviewRemaining: reviewRemaining,
            newRemaining: newRemaining
        )
    }
}
