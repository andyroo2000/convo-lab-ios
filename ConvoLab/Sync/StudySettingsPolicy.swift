import Foundation

enum StudySettingsPolicy {
    static func accepts(
        newCardsPerDay: Int,
        lessonBatchSize: Int,
        reviewTimeBudgetMinutes: Int?,
        newCardLaneWeights: StudyNewCardLaneWeights? = nil,
        capabilities: StudyCapabilities = .fallback
    ) -> Bool {
        capabilities.settings.newCardsPerDay.range.contains(newCardsPerDay)
            && capabilities.settings.lessonBatchSize.range.contains(lessonBatchSize)
            && reviewTimeBudgetMinutes.map(
                capabilities.settings.reviewTimeBudgetMinutes.range.contains
            ) ?? true
            && newCardLaneWeights.map {
                accepts($0, capabilities: capabilities)
            } ?? true
    }

    static func resolvedReviewTimeBudget(
        responseOverview: StudyOverview? = nil,
        settings: StudySettings?,
        currentOverview: StudyOverview?,
        capabilities: StudyCapabilities = .fallback
    ) -> Int {
        clampedReviewTimeBudget(
            responseOverview?.reviewTimeBudgetMinutes
                ?? responseOverview?.learningReadiness?.reviewTimeBudgetMinutes
                ?? settings?.reviewTimeBudgetMinutes
                ?? currentOverview?.reviewTimeBudgetMinutes
                ?? currentOverview?.learningReadiness?.reviewTimeBudgetMinutes
                ?? capabilities.settings.reviewTimeBudgetMinutes.default,
            capabilities: capabilities
        )
    }

    static func settings(
        from overview: StudyOverview,
        fallbackReviewTimeBudget: Int,
        existingLaneWeights: StudyNewCardLaneWeights? = nil,
        capabilities: StudyCapabilities = .fallback
    ) -> StudySettings {
        StudySettings(
            newCardsPerDay: overview.newCardsPerDay,
            lessonBatchSize: overview.lessonBatchSize,
            reviewTimeBudgetMinutes: clampedReviewTimeBudget(
                overview.reviewTimeBudgetMinutes
                    ?? overview.learningReadiness?.reviewTimeBudgetMinutes
                    ?? fallbackReviewTimeBudget,
                capabilities: capabilities
            ),
            newCardLaneWeights: existingLaneWeights
        )
    }

    static func resolving(
        _ response: StudySettings,
        requestedReviewTimeBudget: Int? = nil,
        requestedLaneWeights: StudyNewCardLaneWeights? = nil,
        fallbackReviewTimeBudget: Int,
        capabilities: StudyCapabilities = .fallback
    ) -> StudySettings {
        StudySettings(
            newCardsPerDay: response.newCardsPerDay,
            lessonBatchSize: response.lessonBatchSize,
            reviewTimeBudgetMinutes: clampedReviewTimeBudget(
                response.includesReviewTimeBudgetMinutes
                    ? response.reviewTimeBudgetMinutes
                    : requestedReviewTimeBudget ?? fallbackReviewTimeBudget,
                capabilities: capabilities
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

    private static func clampedReviewTimeBudget(
        _ value: Int,
        capabilities: StudyCapabilities
    ) -> Int {
        let range = capabilities.settings.reviewTimeBudgetMinutes.range
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func accepts(
        _ weights: StudyNewCardLaneWeights,
        capabilities: StudyCapabilities
    ) -> Bool {
        let limits = capabilities.settings.newCardLaneWeights
        return limits.standard.range.contains(weights.standard)
            && limits.lessonFollowup.range.contains(weights.lessonFollowup)
            && limits.wanikani.range.contains(weights.wanikani)
    }
}
