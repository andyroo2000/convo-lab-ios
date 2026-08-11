import XCTest
@testable import ConvoLab

final class StudySettingsPolicyTests: XCTestCase {
    @MainActor
    func testValidationAcceptsOnlySupportedSettingsRanges() {
        XCTAssertTrue(StudySettingsPolicy.accepts(
            newCardsPerDay: 0,
            lessonBatchSize: 3,
            reviewTimeBudgetMinutes: nil
        ))
        XCTAssertTrue(StudySettingsPolicy.accepts(
            newCardsPerDay: 1_000,
            lessonBatchSize: 10,
            reviewTimeBudgetMinutes: 240
        ))
        XCTAssertFalse(StudySettingsPolicy.accepts(
            newCardsPerDay: -1,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 90
        ))
        XCTAssertFalse(StudySettingsPolicy.accepts(
            newCardsPerDay: 20,
            lessonBatchSize: 11,
            reviewTimeBudgetMinutes: 90
        ))
        XCTAssertFalse(StudySettingsPolicy.accepts(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 14
        ))
    }

    @MainActor
    func testLegacyResponsePreservesRequestedOrFallbackBudgetWithinBounds() {
        let legacy = StudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            includesReviewTimeBudgetMinutes: false
        )
        XCTAssertEqual(
            StudySettingsPolicy.resolving(
                legacy,
                requestedReviewTimeBudget: 150,
                fallbackReviewTimeBudget: 90
            ).reviewTimeBudgetMinutes,
            150
        )
        XCTAssertEqual(
            StudySettingsPolicy.resolving(
                legacy,
                fallbackReviewTimeBudget: 500
            ).reviewTimeBudgetMinutes,
            240
        )

        let explicit = StudySettings(
            newCardsPerDay: 20,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 10
        )
        XCTAssertEqual(
            StudySettingsPolicy.resolving(
                explicit,
                requestedReviewTimeBudget: 150,
                fallbackReviewTimeBudget: 90
            ).reviewTimeBudgetMinutes,
            15
        )
    }

    @MainActor
    func testApplyingSettingsUpdatesEveryOverviewSettingAndPreservesCounts() {
        let overview = StudyOverview(
            dueCount: 7,
            newCount: 4,
            reviewCount: 11,
            totalCards: 30,
            newCardsPerDay: 10,
            newCardsAvailableToday: 3,
            failedCount: 2,
            failedDueCount: 1,
            lessonBatchSize: 5,
            reviewTimeBudgetMinutes: 90,
            learningReadiness: StudyLearningReadiness(
                recommendation: "ready",
                readinessLevel: "ready",
                sampleSize: 40,
                sufficientData: true,
                recentRecall: 0.95,
                targetRecall: 0.9,
                dueBacklog: 7,
                apprenticeCount: 3,
                projectedSevenDayReviews: 70,
                timedReviewSampleSize: 40,
                medianReviewDurationSeconds: 60,
                projectedDailyReviewMinutes: 30,
                reviewTimeBudgetMinutes: 90,
                reviewTimeHeadroomMinutes: 60,
                suggestedBatchSize: 5
            )
        )
        let projected = StudySettingsPolicy.applying(
            StudySettings(
                newCardsPerDay: 24,
                lessonBatchSize: 8,
                reviewTimeBudgetMinutes: 45
            ),
            to: overview
        )

        XCTAssertEqual(projected.newCardsPerDay, 24)
        XCTAssertEqual(projected.lessonBatchSize, 8)
        XCTAssertEqual(projected.reviewTimeBudgetMinutes, 45)
        XCTAssertEqual(projected.dueCount, 7)
        XCTAssertEqual(projected.newCount, 4)
        XCTAssertEqual(projected.reviewCount, 11)
        XCTAssertEqual(projected.totalCards, 30)
        XCTAssertEqual(projected.learningReadiness?.reviewTimeBudgetMinutes, 45)
        XCTAssertEqual(projected.learningReadiness?.reviewTimeHeadroomMinutes, 15)
    }
}
