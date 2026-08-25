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

    func testNewlyStabilizedExcludesCardThatEndsSessionBelowThreshold() {
        let below = makeCard(id: "regressed", stability: 6.5)
        let above = makeCard(id: "regressed", stability: 8)
        let regressed = makeCard(id: "regressed", stability: 5)

        let summary = StudySessionWrapUpSummary.build(
            from: [
                record(id: "1", card: below, cardAfter: above, rating: .good, duration: 900),
                record(id: "2", card: above, cardAfter: regressed, rating: .again, duration: 700),
            ]
        )

        XCTAssertTrue(summary.newlyStabilizedCards.isEmpty)
    }

    func testFirstPassRecallUsesReviewTimeWhenAsyncResultsArriveOutOfOrder() {
        let card = makeCard(id: "ordered", stability: 2)
        let summary = StudySessionWrapUpSummary.build(
            from: [
                record(id: "2", card: card, rating: .again, duration: 500),
                record(id: "1", card: card, rating: .good, duration: 500),
            ]
        )

        XCTAssertEqual(summary.firstPassRecall, 1)
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

    func testSummaryMergesLocalAndServerIdentitiesForTheSameCard() {
        let local = makeCard(id: "local", stability: 2)
        let synchronized = makeCard(id: "local", syncId: "server", stability: 2)

        let summary = StudySessionWrapUpSummary.build(
            from: [
                record(id: "1", card: local, rating: .again, duration: 1_000),
                record(id: "2", card: synchronized, rating: .good, duration: 2_000),
            ]
        )

        XCTAssertEqual(summary.toughestCards.count, 1)
        XCTAssertEqual(summary.toughestCards.first?.missCount, 1)
        XCTAssertEqual(summary.firstPassRecall, 0)
    }

    func testCardTimerExcludesTimeWhilePaused() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var timer = StudySessionCardTimer(startedAt: startedAt)

        timer.pause(at: Date(timeIntervalSince1970: 105))
        timer.resume(at: Date(timeIntervalSince1970: 1_005))

        XCTAssertEqual(
            timer.duration(at: Date(timeIntervalSince1970: 1_010)),
            10
        )
    }

    func testSummaryCountsNetBurnedChangePerCard() {
        let almostBurned = makeCard(id: "crossed", stability: 364)
        let burned = makeCard(id: "crossed", stability: 365)
        let regressedBurned = makeCard(id: "regressed", stability: 400)
        let regressed = makeCard(id: "regressed", stability: 100)

        let summary = StudySessionWrapUpSummary.build(
            from: [
                record(
                    id: "1",
                    card: almostBurned,
                    cardAfter: burned,
                    rating: .good,
                    duration: 500
                ),
                record(
                    id: "2",
                    card: regressedBurned,
                    cardAfter: regressed,
                    rating: .again,
                    duration: 500
                ),
            ]
        )

        XCTAssertEqual(summary.burnedCountChange, 0)
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
            durationMilliseconds: duration,
            reviewedAt: Date(timeIntervalSince1970: TimeInterval(Int(id) ?? 0))
        )
    }

    private func makeCard(
        id: String,
        syncId: String? = nil,
        queueState: String = "review",
        stability: Double
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncId,
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
