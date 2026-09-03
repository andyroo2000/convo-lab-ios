import Foundation

struct StudyOverview: nonisolated Codable, Sendable {
    let dueCount: Int
    let failedCount: Int?
    let failedDueCount: Int?
    let newCount: Int
    let reviewCount: Int
    let totalCards: Int
    let newCardsPerDay: Int
    let newCardsAvailableToday: Int?
    let lessonBatchSize: Int
    let reviewTimeBudgetMinutes: Int?
    let masterySpread: StudyMasterySpread?
    let jlptMastery: StudyJLPTMastery?
    let learningReadiness: StudyLearningReadiness?

    init(
        dueCount: Int,
        newCount: Int,
        reviewCount: Int,
        totalCards: Int = 0,
        newCardsPerDay: Int,
        newCardsAvailableToday: Int?,
        failedCount: Int? = nil,
        failedDueCount: Int? = nil,
        lessonBatchSize: Int = 5,
        reviewTimeBudgetMinutes: Int? = nil,
        masterySpread: StudyMasterySpread? = nil,
        jlptMastery: StudyJLPTMastery? = nil,
        learningReadiness: StudyLearningReadiness? = nil
    ) {
        self.dueCount = dueCount
        self.failedCount = failedCount
        self.failedDueCount = failedDueCount
        self.newCount = newCount
        self.reviewCount = reviewCount
        self.totalCards = totalCards
        self.newCardsPerDay = newCardsPerDay
        self.newCardsAvailableToday = newCardsAvailableToday
        self.lessonBatchSize = lessonBatchSize
        self.reviewTimeBudgetMinutes = reviewTimeBudgetMinutes
        self.masterySpread = masterySpread
        self.jlptMastery = jlptMastery
        self.learningReadiness = learningReadiness
    }

    private enum CodingKeys: String, CodingKey {
        case dueCount
        case failedCount
        case failedDueCount
        case newCount
        case reviewCount
        case totalCards
        case newCardsPerDay
        case newCardsAvailableToday
        case lessonBatchSize
        case reviewTimeBudgetMinutes
        case masterySpread
        case jlptMastery
        case learningReadiness

        case legacyDueCount = "due_count"
        case legacyFailedCount = "failed_count"
        case legacyFailedDueCount = "failed_due_count"
        case legacyNewCount = "new_count"
        case legacyReviewCount = "review_count"
        case legacyTotalCards = "total_cards"
        case legacyNewCardsPerDay = "new_cards_per_day"
        case legacyNewCardsAvailableToday = "new_cards_available_today"
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dueCount = try container.decodeIfPresent(Int.self, forKey: .dueCount)
            ?? container.decode(Int.self, forKey: .legacyDueCount)
        failedCount = try container.decodeIfPresent(Int.self, forKey: .failedCount)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyFailedCount)
        failedDueCount = try container.decodeIfPresent(Int.self, forKey: .failedDueCount)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyFailedDueCount)
        newCount = try container.decodeIfPresent(Int.self, forKey: .newCount)
            ?? container.decode(Int.self, forKey: .legacyNewCount)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount)
            ?? container.decode(Int.self, forKey: .legacyReviewCount)
        totalCards = try container.decodeIfPresent(Int.self, forKey: .totalCards)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyTotalCards)
            ?? 0
        newCardsPerDay = try container.decodeIfPresent(Int.self, forKey: .newCardsPerDay)
            ?? container.decode(Int.self, forKey: .legacyNewCardsPerDay)
        newCardsAvailableToday = try container.decodeIfPresent(Int.self, forKey: .newCardsAvailableToday)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyNewCardsAvailableToday)
        lessonBatchSize = try container.decodeIfPresent(Int.self, forKey: .lessonBatchSize) ?? 5
        reviewTimeBudgetMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .reviewTimeBudgetMinutes
        )
        masterySpread = try container.decodeIfPresent(StudyMasterySpread.self, forKey: .masterySpread)
        jlptMastery = try container.decodeIfPresent(StudyJLPTMastery.self, forKey: .jlptMastery)
        learningReadiness = try container.decodeIfPresent(
            StudyLearningReadiness.self,
            forKey: .learningReadiness
        )
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dueCount, forKey: .dueCount)
        try container.encodeIfPresent(failedCount, forKey: .failedCount)
        try container.encodeIfPresent(failedDueCount, forKey: .failedDueCount)
        try container.encode(newCount, forKey: .newCount)
        try container.encode(reviewCount, forKey: .reviewCount)
        try container.encode(totalCards, forKey: .totalCards)
        try container.encode(newCardsPerDay, forKey: .newCardsPerDay)
        try container.encodeIfPresent(newCardsAvailableToday, forKey: .newCardsAvailableToday)
        try container.encode(lessonBatchSize, forKey: .lessonBatchSize)
        try container.encodeIfPresent(reviewTimeBudgetMinutes, forKey: .reviewTimeBudgetMinutes)
        try container.encodeIfPresent(masterySpread, forKey: .masterySpread)
        try container.encodeIfPresent(jlptMastery, forKey: .jlptMastery)
        try container.encodeIfPresent(learningReadiness, forKey: .learningReadiness)
    }

    func updatingReviewTimeBudget(
        to budgetMinutes: Int,
        fallbackJLPTMastery: StudyJLPTMastery? = nil
    ) -> Self {
        Self(
            dueCount: dueCount,
            newCount: newCount,
            reviewCount: reviewCount,
            totalCards: totalCards,
            newCardsPerDay: newCardsPerDay,
            newCardsAvailableToday: newCardsAvailableToday,
            failedCount: failedCount,
            failedDueCount: failedDueCount,
            lessonBatchSize: lessonBatchSize,
            reviewTimeBudgetMinutes: budgetMinutes,
            masterySpread: masterySpread,
            jlptMastery: jlptMastery ?? fallbackJLPTMastery,
            learningReadiness: learningReadiness?.updatingReviewTimeBudget(to: budgetMinutes)
        )
    }
}

struct StudySettings: nonisolated Codable, Equatable, Sendable {
    let newCardsPerDay: Int
    let lessonBatchSize: Int
    let reviewTimeBudgetMinutes: Int
    let newCardLaneWeights: StudyNewCardLaneWeights?
    let includesReviewTimeBudgetMinutes: Bool

    init(
        newCardsPerDay: Int,
        lessonBatchSize: Int = 5,
        reviewTimeBudgetMinutes: Int = 90,
        newCardLaneWeights: StudyNewCardLaneWeights? = nil,
        includesReviewTimeBudgetMinutes: Bool = true
    ) {
        self.newCardsPerDay = newCardsPerDay
        self.lessonBatchSize = lessonBatchSize
        self.reviewTimeBudgetMinutes = reviewTimeBudgetMinutes
        self.newCardLaneWeights = newCardLaneWeights
        self.includesReviewTimeBudgetMinutes = includesReviewTimeBudgetMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case newCardsPerDay
        case lessonBatchSize
        case reviewTimeBudgetMinutes
        case newCardLaneWeights
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newCardsPerDay = try container.decode(Int.self, forKey: .newCardsPerDay)
        lessonBatchSize = try container.decodeIfPresent(Int.self, forKey: .lessonBatchSize) ?? 5
        reviewTimeBudgetMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .reviewTimeBudgetMinutes
        ) ?? 90
        newCardLaneWeights = try container.decodeIfPresent(
            StudyNewCardLaneWeights.self,
            forKey: .newCardLaneWeights
        )
        if container.contains(.reviewTimeBudgetMinutes) {
            includesReviewTimeBudgetMinutes = !(try container.decodeNil(
                forKey: .reviewTimeBudgetMinutes
            ))
        } else {
            includesReviewTimeBudgetMinutes = false
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(newCardsPerDay, forKey: .newCardsPerDay)
        try container.encode(lessonBatchSize, forKey: .lessonBatchSize)
        try container.encode(reviewTimeBudgetMinutes, forKey: .reviewTimeBudgetMinutes)
        try container.encodeIfPresent(newCardLaneWeights, forKey: .newCardLaneWeights)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.newCardsPerDay == rhs.newCardsPerDay
            && lhs.lessonBatchSize == rhs.lessonBatchSize
            && lhs.reviewTimeBudgetMinutes == rhs.reviewTimeBudgetMinutes
            && lhs.newCardLaneWeights == rhs.newCardLaneWeights
    }
}

struct StudyCapabilities: nonisolated Codable, Equatable, Sendable {
    struct IntegerSetting: nonisolated Codable, Equatable, Sendable {
        let `default`: Int
        let min: Int
        let max: Int

        var range: ClosedRange<Int> {
            Swift.min(min, max)...Swift.max(min, max)
        }

        private enum CodingKeys: String, CodingKey {
            case `default`, min, max
        }

        nonisolated init(default: Int, min: Int, max: Int) {
            self.default = `default`
            self.min = min
            self.max = max
        }

        nonisolated init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let decodedDefault = try values.decode(Int.self, forKey: .default)
            let decodedMin = try values.decode(Int.self, forKey: .min)
            let decodedMax = try values.decode(Int.self, forKey: .max)
            guard decodedMin <= decodedMax,
                  decodedMin...decodedMax ~= decodedDefault
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .default,
                    in: values,
                    debugDescription: "Capability default and bounds must form a valid range."
                )
            }
            self.init(default: decodedDefault, min: decodedMin, max: decodedMax)
        }
    }

    struct Settings: nonisolated Codable, Equatable, Sendable {
        struct NewCardLaneWeights: nonisolated Codable, Equatable, Sendable {
            let standard: IntegerSetting
            let lessonFollowup: IntegerSetting
            let wanikani: IntegerSetting
        }

        let newCardsPerDay: IntegerSetting
        let lessonBatchSize: IntegerSetting
        let reviewTimeBudgetMinutes: IntegerSetting
        let newCardLaneWeights: NewCardLaneWeights
    }

    struct CardAuthoring: nonisolated Codable, Equatable, Sendable {
        struct Limits: nonisolated Codable, Equatable, Sendable {
            let combinedPayloadBytes: Int
            let payloadDepth: Int
            let imagePromptCharacters: Int
            let imageUploadBytes: Int
        }

        // Keep server-advertised identifiers as strings so a newly introduced
        // capability does not make the entire contract undecodable on an older app.
        let creationKinds: [String]
        let imagePlacements: [String]
        let previewAudioRoles: [String]
        let defaultAnswerAudioVoiceId: String
        let defaultFemaleAnswerAudioVoiceId: String
        let limits: Limits
    }

    struct DailyAudio: nonisolated Codable, Equatable, Sendable {
        let targetDurationMinutes: IntegerSetting
    }

    struct OfflineReserve: nonisolated Codable, Equatable, Sendable {
        let days: Int
        let maxScheduledCards: Int
    }

    struct Imports: nonisolated Codable, Equatable, Sendable {
        let maxArchiveBytes: Int
    }

    struct StudyActivity: nonisolated Codable, Equatable, Sendable {
        // Raw identifiers keep a future activity/category from invalidating the
        // rest of the capabilities contract on an older client.
        let categoriesByActivity: [String: String]
    }

    let version: Int
    let settings: Settings
    let cardAuthoring: CardAuthoring
    let dailyAudio: DailyAudio
    let offlineReserve: OfflineReserve
    let imports: Imports
    let studyActivity: StudyActivity

    static let fallback = Self(
        version: 1,
        settings: Settings(
            newCardsPerDay: IntegerSetting(default: 20, min: 0, max: 1_000),
            lessonBatchSize: IntegerSetting(default: 5, min: 3, max: 10),
            reviewTimeBudgetMinutes: IntegerSetting(default: 90, min: 15, max: 240),
            newCardLaneWeights: Settings.NewCardLaneWeights(
                standard: IntegerSetting(default: 3, min: 1, max: 20),
                lessonFollowup: IntegerSetting(default: 1, min: 0, max: 20),
                wanikani: IntegerSetting(default: 1, min: 0, max: 20)
            )
        ),
        cardAuthoring: CardAuthoring(
            creationKinds: StudyCardCreationKind.allCases.map(\.rawValue),
            imagePlacements: StudyCardDraft.ImagePlacement.allCases.map(\.rawValue),
            previewAudioRoles: ["prompt", "answer"],
            defaultAnswerAudioVoiceId: StudyAnswerVoice.defaultVoice.id,
            defaultFemaleAnswerAudioVoiceId: "fishaudio:9639f090aa6346329d7d3aca7e6b7226",
            limits: CardAuthoring.Limits(
                combinedPayloadBytes: 24_576,
                payloadDepth: 8,
                imagePromptCharacters: 1_000,
                imageUploadBytes: 10_485_760
            )
        ),
        dailyAudio: DailyAudio(
            targetDurationMinutes: IntegerSetting(default: 30, min: 5, max: 60)
        ),
        offlineReserve: OfflineReserve(days: 5, maxScheduledCards: 1_000),
        imports: Imports(maxArchiveBytes: 2_147_483_648),
        studyActivity: StudyActivity(
            categoriesByActivity: StudyActivityKind.allCases.reduce(into: [:]) {
                $0[$1.rawValue] = $1.offlineFallbackCategory.rawValue
            }
        )
    )
}

struct StudyNewCardLaneWeights: nonisolated Codable, Equatable, Sendable {
    var standard: Int
    var lessonFollowup: Int
    var wanikani: Int

    var total: Int { standard + lessonFollowup + wanikani }

    func percentage(for weight: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(weight) / Double(total) * 100).rounded())
    }
}

struct UpdateStudySettingsRequest: Encodable, Equatable, Sendable {
    let newCardsPerDay: Int
    let lessonBatchSize: Int
    let reviewTimeBudgetMinutes: Int?
    let newCardLaneWeights: StudyNewCardLaneWeights?

    private enum CodingKeys: String, CodingKey {
        case newCardsPerDay
        case lessonBatchSize
        case reviewTimeBudgetMinutes
        case newCardLaneWeights
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(newCardsPerDay, forKey: .newCardsPerDay)
        try container.encode(lessonBatchSize, forKey: .lessonBatchSize)
        try container.encodeIfPresent(reviewTimeBudgetMinutes, forKey: .reviewTimeBudgetMinutes)
        try container.encodeIfPresent(newCardLaneWeights, forKey: .newCardLaneWeights)
    }
}

struct StudyMasterySpread: nonisolated Codable, Equatable, Sendable {
    let apprentice: Int
    let guru: Int
    let master: Int
    let enlightened: Int
    let burned: Int
}

struct StudyJLPTMastery: nonisolated Codable, Equatable, Sendable {
    let n5: StudyJLPTLevelMastery
    let n4: StudyJLPTLevelMastery?

    init(n5: StudyJLPTLevelMastery, n4: StudyJLPTLevelMastery? = nil) {
        self.n5 = n5
        self.n4 = n4
    }

    private enum CodingKeys: String, CodingKey {
        case n5 = "N5"
        case n4 = "N4"
    }
}

struct StudyJLPTLevelMastery: nonisolated Codable, Equatable, Sendable {
    let vocabulary: StudyJLPTMasteryMetric
    let grammar: StudyJLPTMasteryMetric
}

struct StudyJLPTMasteryMetric: nonisolated Codable, Equatable, Sendable {
    let masteryPercent: Int
    let known: Int?
    let knownFromCards: Int?
    let knownFromWaniKani: Int?
    let knownFromBoth: Int?
    let matched: Int?
    let covered: Int
    let total: Int

    init(
        masteryPercent: Int,
        known: Int? = nil,
        knownFromCards: Int? = nil,
        knownFromWaniKani: Int? = nil,
        knownFromBoth: Int? = nil,
        matched: Int? = nil,
        covered: Int,
        total: Int
    ) {
        self.masteryPercent = masteryPercent
        self.known = known
        self.knownFromCards = knownFromCards
        self.knownFromWaniKani = knownFromWaniKani
        self.knownFromBoth = knownFromBoth
        self.matched = matched
        self.covered = covered
        self.total = total
    }
}

struct StudyLearningReadiness: nonisolated Codable, Equatable, Sendable {
    let recommendation: String
    let readinessLevel: String?
    let displayStatus: String?
    let displaySummary: String?
    let sampleSize: Int
    let sufficientData: Bool
    let recentRecall: Double?
    let targetRecall: Double
    let dueBacklog: Int
    let apprenticeCount: Int
    let projectedSevenDayReviews: Int
    let timedReviewSampleSize: Int?
    let medianReviewDurationSeconds: Double?
    let projectedDailyReviewMinutes: Int?
    let reviewTimeBudgetMinutes: Int?
    let reviewTimeHeadroomMinutes: Int?
    let suggestedBatchSize: Int

    init(
        recommendation: String,
        readinessLevel: String?,
        displayStatus: String? = nil,
        displaySummary: String? = nil,
        sampleSize: Int,
        sufficientData: Bool,
        recentRecall: Double?,
        targetRecall: Double,
        dueBacklog: Int,
        apprenticeCount: Int,
        projectedSevenDayReviews: Int,
        timedReviewSampleSize: Int?,
        medianReviewDurationSeconds: Double?,
        projectedDailyReviewMinutes: Int?,
        reviewTimeBudgetMinutes: Int?,
        reviewTimeHeadroomMinutes: Int?,
        suggestedBatchSize: Int
    ) {
        self.recommendation = recommendation
        self.readinessLevel = readinessLevel
        self.displayStatus = displayStatus
        self.displaySummary = displaySummary
        self.sampleSize = sampleSize
        self.sufficientData = sufficientData
        self.recentRecall = recentRecall
        self.targetRecall = targetRecall
        self.dueBacklog = dueBacklog
        self.apprenticeCount = apprenticeCount
        self.projectedSevenDayReviews = projectedSevenDayReviews
        self.timedReviewSampleSize = timedReviewSampleSize
        self.medianReviewDurationSeconds = medianReviewDurationSeconds
        self.projectedDailyReviewMinutes = projectedDailyReviewMinutes
        self.reviewTimeBudgetMinutes = reviewTimeBudgetMinutes
        self.reviewTimeHeadroomMinutes = reviewTimeHeadroomMinutes
        self.suggestedBatchSize = suggestedBatchSize
    }

    func updatingReviewTimeBudget(to budgetMinutes: Int) -> Self {
        Self(
            recommendation: recommendation,
            readinessLevel: readinessLevel,
            displayStatus: displayStatus,
            displaySummary: displaySummary,
            sampleSize: sampleSize,
            sufficientData: sufficientData,
            recentRecall: recentRecall,
            targetRecall: targetRecall,
            dueBacklog: dueBacklog,
            apprenticeCount: apprenticeCount,
            projectedSevenDayReviews: projectedSevenDayReviews,
            timedReviewSampleSize: timedReviewSampleSize,
            medianReviewDurationSeconds: medianReviewDurationSeconds,
            projectedDailyReviewMinutes: projectedDailyReviewMinutes,
            reviewTimeBudgetMinutes: budgetMinutes,
            reviewTimeHeadroomMinutes: projectedDailyReviewMinutes.map { budgetMinutes - $0 },
            suggestedBatchSize: suggestedBatchSize
        )
    }
}
