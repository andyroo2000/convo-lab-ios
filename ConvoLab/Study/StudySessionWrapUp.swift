import Foundation

struct StudySessionReviewRecord: Identifiable, Equatable, Sendable {
    let id: String
    let cardBefore: StudyCard
    let cardAfter: StudyCard?
    let rating: ReviewRating
    let durationMilliseconds: Int
    let reviewedAt: Date
}

struct StudySessionToughCard: Identifiable, Equatable, Sendable {
    let card: StudyCard
    let missCount: Int
    let durationMilliseconds: Int

    var id: String { card.id.lowercased() }
}

struct StudySessionCardTimer: Equatable, Sendable {
    private(set) var elapsed: TimeInterval = 0
    private(set) var runningSince: Date?

    init(startedAt: Date, isRunning: Bool = true) {
        runningSince = isRunning ? startedAt : nil
    }

    mutating func reset(at date: Date, isRunning: Bool) {
        elapsed = 0
        runningSince = isRunning ? date : nil
    }

    mutating func pause(at date: Date) {
        guard let runningSince else { return }
        elapsed += max(0, date.timeIntervalSince(runningSince))
        self.runningSince = nil
    }

    mutating func resume(at date: Date) {
        guard runningSince == nil else { return }
        runningSince = date
    }

    func duration(at date: Date) -> TimeInterval {
        elapsed + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }
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

        let chronologicalRecords = records.sorted {
            if $0.reviewedAt != $1.reviewedAt { return $0.reviewedAt < $1.reviewedAt }
            return $0.id < $1.id
        }
        var identityGroups: [Set<String>] = []
        for record in chronologicalRecords {
            var identifiers = StudyCardIdentity.identifiers(for: record.cardBefore)
            if let cardAfter = record.cardAfter {
                identifiers.formUnion(StudyCardIdentity.identifiers(for: cardAfter))
            }
            let matchingIndices = identityGroups.indices.filter {
                !identityGroups[$0].isDisjoint(with: identifiers)
            }
            for index in matchingIndices.reversed() {
                identifiers.formUnion(identityGroups.remove(at: index))
            }
            identityGroups.append(identifiers)
        }

        func identity(for card: StudyCard) -> String {
            let identifiers = StudyCardIdentity.identifiers(for: card)
            return identityGroups.first { !$0.isDisjoint(with: identifiers) }?.min()
                ?? card.reviewCardID.lowercased()
        }

        for record in chronologicalRecords {
            let identity = identity(for: record.cardBefore)
            // Recall measures established memories, not first exposure or learning steps.
            if firstAttempts[identity] == nil,
               ["review", "relearning"].contains(record.cardBefore.state.queueState)
            {
                firstAttempts[identity] = record
            }

            if let cardAfter = record.cardAfter {
                if (cardAfter.fsrsStability ?? 0) < 7 {
                    stabilized.removeValue(forKey: identity)
                } else if (record.cardBefore.fsrsStability ?? 0) < 7
                            || stabilized[identity] != nil
                {
                    stabilized[identity] = cardAfter
                }
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
