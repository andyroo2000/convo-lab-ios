import XCTest
@testable import ConvoLab

@MainActor
final class StudySessionCountsTests: XCTestCase {
    func testRemainingStudyReflectsAnyAuthoritativeBucket() {
        XCTAssertFalse(
            StudySessionCounts(
                failedDue: 0,
                reviewRemaining: 0,
                newRemaining: 0
            ).hasRemainingStudy
        )
        XCTAssertTrue(
            StudySessionCounts(
                failedDue: 0,
                reviewRemaining: 1,
                newRemaining: 0
            ).hasRemainingStudy
        )
    }

    func testNewLessonAvailabilityDoesNotClaimMoreReviewsAreReady() {
        let counts = StudySessionCounts(
            failedDue: 0,
            reviewRemaining: 0,
            newRemaining: 1
        )

        XCTAssertFalse(counts.hasRemainingReviews)
        XCTAssertTrue(counts.hasRemainingStudy)
    }

    func testOfflineReadinessTargetUsesAuthoritativeDueBacklogBeyondLoadedCards() {
        let counts = StudySessionCounts(
            failedDue: 8,
            reviewRemaining: 380,
            newRemaining: 0
        )

        XCTAssertEqual(
            counts.offlineReadinessTarget(
                loadedCardCount: 300,
                fiveDayNewCardTarget: 100
            ),
            388
        )
    }

    func testOverviewDecodesAuthoritativeFailedCounts() throws {
        let overview = try StorageCodec.decoder.decode(
            StudyOverview.self,
            from: Data(
                #"""
                {
                  "due_count": 8,
                  "failed_count": 2,
                  "failed_due_count": 1,
                  "new_count": 4,
                  "review_count": 6,
                  "total_cards": 17,
                  "new_cards_per_day": 20,
                  "new_cards_available_today": 0
                }
                """#.utf8
            )
        )

        XCTAssertEqual(overview.failedCount, 2)
        XCTAssertEqual(overview.failedDueCount, 1)
        XCTAssertEqual(overview.totalCards, 17)
        XCTAssertEqual(overview.lessonBatchSize, 5)
    }

    func testOverviewDecodesLearningReadinessAndMasterySpread() throws {
        let overview = try StorageCodec.decoder.decode(
            StudyOverview.self,
            from: Data(
                #"""
                {
                  "dueCount": 8,
                  "failedCount": 2,
                  "newCount": 4,
                  "reviewCount": 6,
                  "totalCards": 42,
                  "newCardsPerDay": 20,
                  "newCardsAvailableToday": 4,
                  "lessonBatchSize": 8,
                  "reviewTimeBudgetMinutes": 90,
                  "masterySpread": {
                    "apprentice": 4,
                    "guru": 3,
                    "master": 2,
                    "enlightened": 1,
                    "burned": 5
                  },
                  "learningReadiness": {
                    "recommendation": "caution",
                    "readinessLevel": "ease_up",
                    "sampleSize": 50,
                    "sufficientData": true,
                    "recentRecall": 0.84,
                    "targetRecall": 0.9,
                    "dueBacklog": 10,
                    "apprenticeCount": 4,
                    "projectedSevenDayReviews": 22,
                    "timedReviewSampleSize": 40,
                    "medianReviewDurationSeconds": 18.5,
                    "projectedDailyReviewMinutes": 58,
                    "reviewTimeBudgetMinutes": 90,
                    "reviewTimeHeadroomMinutes": 32,
                    "suggestedBatchSize": 4
                  }
                }
                """#.utf8
            )
        )

        XCTAssertEqual(overview.lessonBatchSize, 8)
        XCTAssertEqual(overview.totalCards, 42)
        XCTAssertEqual(overview.reviewTimeBudgetMinutes, 90)
        XCTAssertEqual(overview.masterySpread?.burned, 5)
        XCTAssertEqual(overview.learningReadiness?.recommendation, "caution")
        XCTAssertEqual(overview.learningReadiness?.readinessLevel, "ease_up")
        XCTAssertEqual(overview.learningReadiness?.projectedDailyReviewMinutes, 58)
        XCTAssertEqual(overview.learningReadiness?.reviewTimeBudgetMinutes, 90)
        XCTAssertEqual(overview.learningReadiness?.reviewTimeHeadroomMinutes, 32)
        XCTAssertEqual(overview.learningReadiness?.suggestedBatchSize, 4)

        let updatedReadiness = try XCTUnwrap(overview.learningReadiness)
            .updatingReviewTimeBudget(to: 45)
        XCTAssertEqual(updatedReadiness.reviewTimeBudgetMinutes, 45)
        XCTAssertEqual(updatedReadiness.projectedDailyReviewMinutes, 58)
        XCTAssertEqual(updatedReadiness.reviewTimeHeadroomMinutes, -13)
    }

    func testQueuedLessonCountIgnoresDailyGuidanceAllowance() {
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
            failedCount: 1,
            failedDueCount: 1
        )

        let counts = StudySessionCounts.calculate(cards: cards, overview: overview)

        XCTAssertEqual(
            counts,
            StudySessionCounts(failedDue: 1, reviewRemaining: 2, newRemaining: 1)
        )
    }

    func testLessonAvailabilityIsNotLimitedToReviewSessionCards() {
        let overview = StudyOverview(
            dueCount: 5,
            newCount: 12,
            reviewCount: 5,
            newCardsPerDay: 20,
            newCardsAvailableToday: 6,
            failedCount: 0
        )

        let counts = StudySessionCounts.calculate(
            cards: [makeCard(id: "review", queueState: "review")],
            overview: overview
        )

        XCTAssertEqual(counts.newRemaining, 12)
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

    func testFutureLoadedFailureDoesNotClaimAReviewIsReady() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let futureFailure = makeCard(
            id: "failed-future",
            queueState: "relearning",
            failedAt: now,
            dueAt: now.addingTimeInterval(10 * 60)
        )

        let counts = StudySessionCounts.calculate(
            cards: [futureFailure],
            overview: nil,
            at: now
        )

        XCTAssertEqual(counts.failedDue, 0)
    }

    func testReviewedFailureOptimisticallyDecrementsAuthoritativeCount() {
        let overview = StudyOverview(
            dueCount: 2,
            newCount: 0,
            reviewCount: 0,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 2,
            failedDueCount: 2
        )

        let counts = StudySessionCounts.calculate(
            cards: [],
            overview: overview,
            resolvedFailedCardIDs: ["failed-1"]
        )

        XCTAssertEqual(counts.failedDue, 1)
    }

    func testFutureRelearningFailureDoesNotClaimAReviewIsReady() {
        let overview = StudyOverview(
            dueCount: 0,
            newCount: 0,
            reviewCount: 0,
            newCardsPerDay: 20,
            newCardsAvailableToday: 0,
            failedCount: 1,
            failedDueCount: 0
        )

        let counts = StudySessionCounts.calculate(cards: [], overview: overview)

        XCTAssertEqual(counts.failedDue, 0)
    }

    func testFirstTimeAgainDoesNotClaimAReviewIsReadyBeforeItsDueTime() {
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
            overview: overview
        )

        XCTAssertEqual(counts.failedDue, 0)
    }

    func testPendingFutureRelearningFailureDoesNotClaimAReviewIsReadyOffline() {
        let counts = StudySessionCounts.calculate(
            cards: [],
            overview: nil,
            retainedFailedCardIDs: ["existing-failure"]
        )

        XCTAssertEqual(counts.failedDue, 0)
    }

    func testOnlyLoadedDueFailuresCountWhileOffline() {
        let cards = [
            makeCard(id: "failed-2", queueState: "relearning", failedAt: .now),
        ]

        let counts = StudySessionCounts.calculate(
            cards: cards,
            overview: nil,
            retainedFailedCardIDs: ["failed-1"]
        )

        XCTAssertEqual(counts.failedDue, 1)
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
        failedAt: Date? = nil,
        dueAt: Date = .now
    ) -> StudyCard {
        StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: dueAt,
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
