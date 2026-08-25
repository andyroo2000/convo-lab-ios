import Foundation

struct StudySessionReviewRecord: Identifiable, Equatable, Sendable {
    let id: String
    let cardBefore: StudyCard
    let cardAfter: StudyCard?
    let rating: ReviewRating
    let durationMilliseconds: Int
}

struct StudySessionToughCard: Identifiable, Equatable, Sendable {
    let card: StudyCard
    let missCount: Int
    let durationMilliseconds: Int

    var id: String { card.reviewCardID.lowercased() }
}

struct StudySessionWrapUpSummary: Equatable, Sendable {
    let reviewsCompleted: Int
    let firstPassRecall: Double?
    let newlyStabilizedCards: [StudyCard]
    let toughestCards: [StudySessionToughCard]

    static func build(from records: [StudySessionReviewRecord]) -> Self {
        var firstAttempts: [String: StudySessionReviewRecord] = [:]
        var stabilized: [String: StudyCard] = [:]
        var aggregates: [String: StudySessionToughCard] = [:]

        for record in records {
            let identity = record.cardBefore.reviewCardID.lowercased()
            if firstAttempts[identity] == nil,
               ["review", "relearning"].contains(record.cardBefore.state.queueState)
            {
                firstAttempts[identity] = record
            }

            if (record.cardBefore.fsrsStability ?? 0) < 7,
               let cardAfter = record.cardAfter,
               (cardAfter.fsrsStability ?? 0) >= 7
            {
                stabilized[identity] = cardAfter
            }

            let existing = aggregates[identity]
            aggregates[identity] = StudySessionToughCard(
                card: record.cardAfter ?? record.cardBefore,
                missCount: (existing?.missCount ?? 0) + (record.rating == .again ? 1 : 0),
                durationMilliseconds: max(
                    existing?.durationMilliseconds ?? 0,
                    max(0, record.durationMilliseconds)
                )
            )
        }

        let firstPassRecall = firstAttempts.isEmpty ? nil : Double(
            firstAttempts.values.count { $0.rating != .again }
        ) / Double(firstAttempts.count)
        let values = Array(aggregates.values)
        let byMisses = values.sorted(by: Self.isTougher).prefix(3)
        let byDuration = values.sorted {
            if $0.durationMilliseconds != $1.durationMilliseconds {
                return $0.durationMilliseconds > $1.durationMilliseconds
            }
            return Self.isTougher($0, $1)
        }.prefix(3)
        var selected: [String: StudySessionToughCard] = [:]
        for item in Array(byMisses) + Array(byDuration) {
            selected[item.id] = item
        }

        return Self(
            reviewsCompleted: records.count,
            firstPassRecall: firstPassRecall,
            newlyStabilizedCards: stabilized.values.sorted {
                $0.promptText.localizedStandardCompare($1.promptText) == .orderedAscending
            },
            toughestCards: selected.values.sorted(by: Self.isTougher).prefix(6).map(\.self)
        )
    }

    private static func isTougher(
        _ lhs: StudySessionToughCard,
        _ rhs: StudySessionToughCard
    ) -> Bool {
        if lhs.missCount != rhs.missCount { return lhs.missCount > rhs.missCount }
        if lhs.durationMilliseconds != rhs.durationMilliseconds {
            return lhs.durationMilliseconds > rhs.durationMilliseconds
        }
        return lhs.id < rhs.id
    }
}

enum StudySessionPracticeQueue {
    static func applying(
        _ rating: ReviewRating,
        to cards: [StudyCard]
    ) -> [StudyCard] {
        guard let first = cards.first else { return [] }
        let remaining = Array(cards.dropFirst())
        return rating == .again ? remaining + [first] : remaining
    }
}
