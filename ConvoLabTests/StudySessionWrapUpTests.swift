import XCTest
@testable import ConvoLab

@MainActor
final class StudySessionWrapUpTests: XCTestCase {
    func testSummaryCalculatesFirstPassRecallAndReviewCount() {
        let first = makeCard(id: "first", queueState: "review", stability: 4)
        let second = makeCard(id: "second", queueState: "relearning", stability: 2)
        let records = [
            record(id: "1", card: first, rating: .again, duration: 2_000),
            record(id: "2", card: first, rating: .good, duration: 1_000),
            record(id: "3", card: second, rating: .good, duration: 1_500),
        ]

        let summary = StudySessionWrapUpSummary.build(from: records)

        XCTAssertEqual(summary.reviewsCompleted, 3)
        XCTAssertEqual(summary.firstPassRecall, 0.5)
    }

    func testSummaryFindsCardsThatCrossWeekLongStability() {
        let before = makeCard(id: "stable", queueState: "review", stability: 6.5)
        let after = makeCard(id: "stable", queueState: "review", stability: 8)

        let summary = StudySessionWrapUpSummary.build(
            from: [record(id: "1", card: before, cardAfter: after, rating: .good, duration: 900)]
        )

        XCTAssertEqual(summary.newlyStabilizedCards.map(\.id), ["stable"])
    }

    func testToughestCombinesRepeatedMissesAndSlowCards() {
        let records = [
            record(id: "1", card: makeCard(id: "missed", stability: 2), rating: .again, duration: 500),
            record(id: "2", card: makeCard(id: "missed", stability: 2), rating: .again, duration: 500),
            record(id: "3", card: makeCard(id: "slow", stability: 2), rating: .good, duration: 9_000),
            record(id: "4", card: makeCard(id: "medium", stability: 2), rating: .good, duration: 4_000),
        ]

        let summary = StudySessionWrapUpSummary.build(from: records)

        XCTAssertEqual(summary.toughestCards.map(\.card.id), ["missed", "slow", "medium"])
        XCTAssertEqual(summary.toughestCards.first?.missCount, 2)
    }

    func testPracticeQueueRetriesAgainWithoutMutatingCards() {
        let first = makeCard(id: "first", stability: 2)
        let second = makeCard(id: "second", stability: 2)

        XCTAssertEqual(
            StudySessionPracticeQueue.applying(.again, to: [first, second]).map(\.id),
            ["second", "first"]
        )
        XCTAssertEqual(
            StudySessionPracticeQueue.applying(.good, to: [first, second]).map(\.id),
            ["second"]
        )
    }

    private func record(
        id: String,
        card: StudyCard,
        cardAfter: StudyCard? = nil,
        rating: ReviewRating,
        duration: Int
    ) -> StudySessionReviewRecord {
        StudySessionReviewRecord(
            id: id,
            cardBefore: card,
            cardAfter: cardAfter,
            rating: rating,
            durationMilliseconds: duration
        )
    }

    private func makeCard(
        id: String,
        queueState: String = "review",
        stability: Double
    ) -> StudyCard {
        StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: .now,
                introducedAt: .now,
                failedAt: nil,
                queueState: queueState,
                scheduler: .object(["stability": .number(stability)]),
                source: .object([:])
            ),
            answerAudioSource: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }
}
