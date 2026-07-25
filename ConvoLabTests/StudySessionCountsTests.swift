import XCTest
@testable import ConvoLab

@MainActor
final class StudySessionCountsTests: XCTestCase {
    func testOverviewDecodesAuthoritativeFailedCount() throws {
        let overview = try StorageCodec.decoder.decode(
            StudyOverview.self,
            from: Data(
                #"""
                {
                  "due_count": 8,
                  "failed_count": 2,
                  "new_count": 4,
                  "review_count": 6,
                  "new_cards_per_day": 20,
                  "new_cards_available_today": 0
                }
                """#.utf8
            )
        )

        XCTAssertEqual(overview.failedCount, 2)
    }

    func testCountsMatchDesktopFailedQueuedAndNewSemantics() {
        let cards = [
            makeCard(id: "failed", queueState: "relearning", failedAt: .now),
            makeCard(id: "review", queueState: "review"),
            makeCard(id: "learning", queueState: "learning"),
            makeCard(id: "new", queueState: "new"),
        ]
        let overview = StudyOverview(
            dueCount: 2,
            newCount: 1,
            reviewCount: 2,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 1
        )

        let counts = StudySessionCounts.calculate(cards: cards, overview: overview)

        XCTAssertEqual(
            counts,
            StudySessionCounts(failedDue: 1, reviewRemaining: 2, newRemaining: 1)
        )
    }

    func testAuthoritativeDueCountIsNotLimitedToLoadedSessionCards() {
        let cards = (0..<300).map {
            makeCard(id: "review-\($0)", queueState: "review")
        }
        let overview = StudyOverview(
            dueCount: 618,
            newCount: 0,
            reviewCount: 618,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 0
        )

        let counts = StudySessionCounts.calculate(cards: cards, overview: overview)

        XCTAssertEqual(counts.reviewRemaining, 618)
    }

    func testLoadedFailuresWinWhenOverviewIsStaleOrUnavailableOffline() {
        let cards = [
            makeCard(id: "failed-1", queueState: "relearning", failedAt: .now),
            makeCard(id: "failed-2", queueState: "relearning", failedAt: .now),
        ]

        let counts = StudySessionCounts.calculate(cards: cards, overview: nil)

        XCTAssertEqual(counts.failedDue, 2)
        XCTAssertEqual(counts.reviewRemaining, 0)
        XCTAssertEqual(counts.newRemaining, 0)
    }

    func testReviewedFailureOptimisticallyDecrementsAuthoritativeCount() {
        let overview = StudyOverview(
            dueCount: 2,
            newCount: 0,
            reviewCount: 0,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 2
        )

        let counts = StudySessionCounts.calculate(
            cards: [],
            overview: overview,
            resolvedFailedCardIDs: ["failed-1"]
        )

        XCTAssertEqual(counts.failedDue, 1)
    }

    func testAgainKeepsAuthoritativeFailureVisibleWhileItWaitsForRelearning() {
        let overview = StudyOverview(
            dueCount: 0,
            newCount: 0,
            reviewCount: 0,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 1
        )

        let counts = StudySessionCounts.calculate(cards: [], overview: overview)

        XCTAssertEqual(counts.failedDue, 1)
    }

    func testFirstTimeAgainIncrementsFailureCountBeforeServerSync() {
        let overview = StudyOverview(
            dueCount: 4,
            newCount: 0,
            reviewCount: 4,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 0
        )

        let counts = StudySessionCounts.calculate(
            cards: [],
            overview: overview,
            newlyFailedCardIDs: ["new-failure"]
        )

        XCTAssertEqual(counts.failedDue, 1)
    }

    func testPendingRelearningFailureSurvivesOfflineRelaunchWithoutOverview() {
        let counts = StudySessionCounts.calculate(
            cards: [],
            overview: nil,
            retainedFailedCardIDs: ["existing-failure"]
        )

        XCTAssertEqual(counts.failedDue, 1)
    }

    func testRelearningFailureAddsToOtherLoadedFailuresWhileOffline() {
        let cards = [
            makeCard(id: "failed-2", queueState: "relearning", failedAt: .now),
        ]

        let counts = StudySessionCounts.calculate(
            cards: cards,
            overview: nil,
            retainedFailedCardIDs: ["failed-1"]
        )

        XCTAssertEqual(counts.failedDue, 2)
    }

    func testDuePendingFailureIsNotCountedTwiceWhenItReturnsToQueue() {
        let card = makeCard(
            id: "failed-1",
            queueState: "relearning",
            failedAt: .now
        )

        let counts = StudySessionCounts.calculate(
            cards: [card],
            overview: nil,
            retainedFailedCardIDs: [card.id]
        )

        XCTAssertEqual(counts.failedDue, 1)
    }

    private func makeCard(
        id: String,
        queueState: String,
        failedAt: Date? = nil
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
                failedAt: failedAt,
                queueState: queueState,
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }
}
