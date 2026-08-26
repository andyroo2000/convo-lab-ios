import Foundation

enum StudySettingsPolicy {
    static let newCardsPerDayRange = 0...1_000
    static let lessonBatchSizeRange = 3...10
    static let reviewTimeBudgetRange = 15...240
    static let standardLaneWeightRange = 1...20
    static let priorityLaneWeightRange = 0...20

    static func accepts(
        newCardsPerDay: Int,
        lessonBatchSize: Int,
        reviewTimeBudgetMinutes: Int?,
        newCardLaneWeights: StudyNewCardLaneWeights? = nil
    ) -> Bool {
        newCardsPerDayRange.contains(newCardsPerDay)
            && lessonBatchSizeRange.contains(lessonBatchSize)
            && reviewTimeBudgetMinutes.map(reviewTimeBudgetRange.contains) ?? true
            && newCardLaneWeights.map(accepts) ?? true
    }

    static func resolvedReviewTimeBudget(
        responseOverview: StudyOverview? = nil,
        settings: StudySettings?,
        currentOverview: StudyOverview?
    ) -> Int {
        clampedReviewTimeBudget(
            responseOverview?.reviewTimeBudgetMinutes
                ?? responseOverview?.learningReadiness?.reviewTimeBudgetMinutes
                ?? settings?.reviewTimeBudgetMinutes
                ?? currentOverview?.reviewTimeBudgetMinutes
                ?? currentOverview?.learningReadiness?.reviewTimeBudgetMinutes
                ?? 90
        )
    }

    static func settings(
        from overview: StudyOverview,
        fallbackReviewTimeBudget: Int,
        existingLaneWeights: StudyNewCardLaneWeights? = nil
    ) -> StudySettings {
        StudySettings(
            newCardsPerDay: overview.newCardsPerDay,
            lessonBatchSize: overview.lessonBatchSize,
            reviewTimeBudgetMinutes: clampedReviewTimeBudget(
                overview.reviewTimeBudgetMinutes
                    ?? overview.learningReadiness?.reviewTimeBudgetMinutes
                    ?? fallbackReviewTimeBudget
            ),
            newCardLaneWeights: existingLaneWeights
        )
    }

    static func resolving(
        _ response: StudySettings,
        requestedReviewTimeBudget: Int? = nil,
        requestedLaneWeights: StudyNewCardLaneWeights? = nil,
        fallbackReviewTimeBudget: Int
    ) -> StudySettings {
        StudySettings(
            newCardsPerDay: response.newCardsPerDay,
            lessonBatchSize: response.lessonBatchSize,
            reviewTimeBudgetMinutes: clampedReviewTimeBudget(
                response.includesReviewTimeBudgetMinutes
                    ? response.reviewTimeBudgetMinutes
                    : requestedReviewTimeBudget ?? fallbackReviewTimeBudget
            ),
            newCardLaneWeights: response.newCardLaneWeights ?? requestedLaneWeights
        )
    }

    static func applying(
        _ settings: StudySettings,
        to overview: StudyOverview,
        preservingJLPTMasteryFrom currentOverview: StudyOverview? = nil
    ) -> StudyOverview {
        StudyOverview(
            dueCount: overview.dueCount,
            newCount: overview.newCount,
            reviewCount: overview.reviewCount,
            totalCards: overview.totalCards,
            newCardsPerDay: settings.newCardsPerDay,
            newCardsAvailableToday: overview.newCardsAvailableToday,
            failedCount: overview.failedCount,
            failedDueCount: overview.failedDueCount,
            lessonBatchSize: settings.lessonBatchSize,
            reviewTimeBudgetMinutes: settings.reviewTimeBudgetMinutes,
            masterySpread: overview.masterySpread,
            jlptMastery: overview.jlptMastery ?? currentOverview?.jlptMastery,
            learningReadiness: overview.learningReadiness?
                .updatingReviewTimeBudget(to: settings.reviewTimeBudgetMinutes)
        )
    }

    private static func clampedReviewTimeBudget(_ value: Int) -> Int {
        min(max(value, reviewTimeBudgetRange.lowerBound), reviewTimeBudgetRange.upperBound)
    }

    private static func accepts(_ weights: StudyNewCardLaneWeights) -> Bool {
        standardLaneWeightRange.contains(weights.standard)
            && priorityLaneWeightRange.contains(weights.lessonFollowup)
            && priorityLaneWeightRange.contains(weights.wanikani)
    }
}
