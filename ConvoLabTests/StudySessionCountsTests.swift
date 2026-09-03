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
                reserveNewCardTarget: 100
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
            from: Data(Self.detailedOverviewJSON.utf8)
        )

        assertOverviewBasics(overview)
        assertMastery(overview)
        try assertReadiness(overview)
        assertBudgetUpdate(overview)
    }

    private func assertOverviewBasics(_ overview: StudyOverview) {
        XCTAssertEqual(overview.lessonBatchSize, 8)
        XCTAssertEqual(overview.totalCards, 42)
        XCTAssertEqual(overview.reviewTimeBudgetMinutes, 90)
        XCTAssertEqual(overview.masterySpread?.burned, 5)
    }

    private func assertMastery(_ overview: StudyOverview) {
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.masteryPercent, 34)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.known, 250)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.knownFromCards, 233)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.knownFromWaniKani, 40)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.knownFromBoth, 23)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.matched, 280)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.covered, 280)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.total, 684)
        XCTAssertEqual(overview.jlptMastery?.n5.grammar.masteryPercent, 21)
        XCTAssertEqual(overview.jlptMastery?.n5.grammar.known, 16)
        XCTAssertEqual(overview.jlptMastery?.n5.grammar.matched, 29)
        XCTAssertEqual(overview.jlptMastery?.n5.grammar.covered, 29)
        XCTAssertEqual(overview.jlptMastery?.n5.grammar.total, 77)
        XCTAssertEqual(overview.jlptMastery?.n4?.vocabulary.masteryPercent, 18)
        XCTAssertEqual(overview.jlptMastery?.n4?.vocabulary.known, 115)
        XCTAssertEqual(overview.jlptMastery?.n4?.vocabulary.knownFromWaniKani, 40)
        XCTAssertEqual(overview.jlptMastery?.n4?.vocabulary.total, 640)
        XCTAssertEqual(overview.jlptMastery?.n4?.grammar.masteryPercent, 9)
        XCTAssertEqual(overview.jlptMastery?.n4?.grammar.total, 89)
    }

    private func assertReadiness(_ overview: StudyOverview) throws {
        XCTAssertEqual(overview.learningReadiness?.recommendation, "caution")
        XCTAssertEqual(overview.learningReadiness?.readinessLevel, "ease_up")
        XCTAssertEqual(overview.learningReadiness?.displayStatus, "Add carefully")
        XCTAssertEqual(
            overview.learningReadiness?.displaySummary,
            "Recent recall is 84%. Target is 90%."
        )
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

    private func assertBudgetUpdate(_ overview: StudyOverview) {
        let narrowOverview = StudyOverview(
            dueCount: 8,
            newCount: 4,
            reviewCount: 6,
            newCardsPerDay: 20,
            newCardsAvailableToday: 4
        ).updatingReviewTimeBudget(
            to: 45,
            fallbackJLPTMastery: overview.jlptMastery
        )
        XCTAssertEqual(narrowOverview.jlptMastery?.n5.vocabulary.masteryPercent, 34)
        XCTAssertEqual(narrowOverview.jlptMastery?.n5.grammar.masteryPercent, 21)
    }

    func testOverviewStillDecodesLegacyMasteryWithoutKnownOrMatchedCounts() throws {
        let overview = try JSONDecoder().decode(
            StudyOverview.self,
            from: Data(
                #"{"dueCount":0,"newCount":0,"reviewCount":0,"newCardsPerDay":20,"jlptMastery":{"N5":{"vocabulary":{"masteryPercent":8,"covered":83,"total":684},"grammar":{"masteryPercent":46,"covered":36,"total":77}}}}"#.utf8
            )
        )

        XCTAssertNil(overview.jlptMastery?.n5.vocabulary.known)
        XCTAssertNil(overview.jlptMastery?.n5.vocabulary.matched)
        XCTAssertEqual(overview.jlptMastery?.n5.vocabulary.covered, 83)
        XCTAssertNil(overview.jlptMastery?.n5.grammar.known)
        XCTAssertNil(overview.jlptMastery?.n5.grammar.matched)
        XCTAssertEqual(overview.jlptMastery?.n5.grammar.covered, 36)
        XCTAssertNil(overview.jlptMastery?.n4)
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
        let overview = makeOverview(
            .init(
                dueCount: 5,
                newCount: 12,
                reviewCount: 5,
                newCardsAvailableToday: 6
            )
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
        let overview = makeOverview(
            .init(
                dueCount: 618,
                reviewCount: 618,
                newCardsAvailableToday: 0
            )
        )

        let counts = StudySessionCounts.calculate(cards: cards, overview: overview)

        XCTAssertEqual(counts.reviewRemaining, 618)
    }

    func testCardsThatBecomeDueOfflineOverrideAStaleCachedOverview() {
        let overview = makeOverview(
            .init(
                reviewCount: 12,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            )
        )
        let cards = [
            makeCard(id: "became-due-1", queueState: "review"),
            makeCard(id: "became-due-2", queueState: "review"),
        ]

        let counts = StudySessionCounts.calculate(cards: cards, overview: overview)

        XCTAssertEqual(counts.reviewRemaining, 2)
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
        let overview = makeOverview(
            .init(
                dueCount: 2,
                newCardsAvailableToday: 0,
                failedCount: 2,
                failedDueCount: 2
            )
        )

        let counts = StudySessionCounts.calculate(
            cards: [],
            overview: overview,
            resolvedFailedCardIDs: ["failed-1"]
        )

        XCTAssertEqual(counts.failedDue, 1)
    }

    func testFutureRelearningFailureDoesNotClaimAReviewIsReady() {
        let overview = makeOverview(
            .init(
                newCardsAvailableToday: 0,
                failedCount: 1,
                failedDueCount: 0
            )
        )

        let counts = StudySessionCounts.calculate(cards: [], overview: overview)

        XCTAssertEqual(counts.failedDue, 0)
    }

    func testFirstTimeAgainDoesNotClaimAReviewIsReadyBeforeItsDueTime() {
        let overview = makeOverview(
            .init(
                dueCount: 4,
                reviewCount: 4,
                newCardsAvailableToday: 0
            )
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

    private func makeOverview(_ fixture: OverviewFixture) -> StudyOverview {
        StudyOverview(
            dueCount: fixture.dueCount,
            newCount: fixture.newCount,
            reviewCount: fixture.reviewCount,
            newCardsPerDay: fixture.newCardsPerDay,
            newCardsAvailableToday: fixture.newCardsAvailableToday,
            failedCount: fixture.failedCount,
            failedDueCount: fixture.failedDueCount
        )
    }

    private struct OverviewFixture {
        var dueCount = 0
        var newCount = 0
        var reviewCount = 0
        var newCardsPerDay = 20
        var newCardsAvailableToday: Int?
        var failedCount = 0
        var failedDueCount: Int?
    }

    private static let detailedOverviewJSON = #"""
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
          "jlptMastery": {
            "N5": {
              "vocabulary": {"masteryPercent": 34, "known": 250, "knownFromCards": 233, "knownFromWaniKani": 40, "knownFromBoth": 23, "matched": 280, "covered": 280, "total": 684},
              "grammar": {"masteryPercent": 21, "known": 16, "knownFromCards": 16, "knownFromWaniKani": 0, "knownFromBoth": 0, "matched": 29, "covered": 29, "total": 77}
            },
            "N4": {
              "vocabulary": {"masteryPercent": 18, "known": 115, "knownFromCards": 90, "knownFromWaniKani": 40, "knownFromBoth": 15, "matched": 130, "covered": 130, "total": 640},
              "grammar": {"masteryPercent": 9, "known": 8, "knownFromCards": 8, "knownFromWaniKani": 0, "knownFromBoth": 0, "matched": 12, "covered": 12, "total": 89}
            }
          },
          "learningReadiness": {
            "recommendation": "caution",
            "readinessLevel": "ease_up",
            "displayStatus": "Add carefully",
            "displaySummary": "Recent recall is 84%. Target is 90%.",
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
        """#
}
