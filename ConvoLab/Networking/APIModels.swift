import Foundation

struct APIEnvelope<Value: Decodable & Sendable>: nonisolated Decodable, Sendable {
    let data: Value
}

struct CurrentUser: nonisolated Codable, Sendable {
    let id: Int
    let name: String
    let email: String
    let emailVerifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case emailVerifiedAt = "email_verified_at"
    }
}

struct MobileTokenResponse: nonisolated Decodable, Sendable {
    struct TokenData: nonisolated Decodable, Sendable {
        let token: String
        let tokenType: String
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case token
            case tokenType = "token_type"
            case expiresAt = "expires_at"
        }
    }

    let data: TokenData
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case email, password
        case deviceName = "device_name"
    }
}

struct RegistrationRequest: Encodable {
    let name: String
    let email: String
    let password: String
    let inviteCode: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        // The Convo Lab compatibility API intentionally keeps inviteCode camel-cased.
        case name, email, password
        case inviteCode = "inviteCode"
        case deviceName = "device_name"
    }
}

struct RegistrationResponse: nonisolated Decodable, Sendable {
    struct RegistrationData: nonisolated Decodable, Sendable {
        let user: CurrentUser
        let token: String
    }

    let data: RegistrationData
}

struct UpdateProfileRequest: Encodable {
    let name: String
    let email: String
}

struct UpdatePasswordRequest: Encodable {
    let currentPassword: String
    let password: String
    let passwordConfirmation: String

    enum CodingKeys: String, CodingKey {
        case password
        case currentPassword = "current_password"
        case passwordConfirmation = "password_confirmation"
    }
}

struct DeleteAccountRequest: Encodable {
    let currentPassword: String

    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
    }
}

struct PasswordResetRequest: Encodable {
    let email: String
}

struct RegenerateAnswerAudioRequest: Encodable, Equatable, Sendable {
    let answerAudioVoiceId: String?
    let answerAudioTextOverride: String?
}

struct RegenerateImageRequest: Encodable, Equatable, Sendable {
    let imagePrompt: String
    let imageRole: String
}

enum StudyCardCreationKind: String, nonisolated Codable, CaseIterable, Identifiable, Sendable {
    case textRecognition = "text-recognition"
    case audioRecognition = "audio-recognition"
    case productionText = "production-text"
    case productionImage = "production-image"
    case cloze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textRecognition: "Text recognition"
        case .audioRecognition: "Audio recognition"
        case .productionText: "Text production"
        case .productionImage: "Image production"
        case .cloze: "Cloze"
        }
    }

    var cardType: StudyCardDraft.CardType {
        switch self {
        case .textRecognition, .audioRecognition: .recognition
        case .productionText, .productionImage: .production
        case .cloze: .cloze
        }
    }

    var defaultImagePlacement: StudyCardDraft.ImagePlacement {
        switch self {
        case .productionImage: .prompt
        case .cloze: .both
        case .textRecognition, .audioRecognition, .productionText: .none
        }
    }
}

// learning-os resolves these ConvoLab compatibility resources directly, so
// card-draft list, detail, mutation, and preview responses are intentionally
// decoded without APIEnvelope.
struct StudyManualCardDraft: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let committedCardId: String?
    let creationKind: StudyCardCreationKind
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let imagePlacement: StudyCardDraft.ImagePlacement
    let imagePrompt: String?
    let previewAudio: JSONValue?
    let previewAudioRole: String?
    let previewImage: JSONValue?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
}

struct StudyManualCardDraftListResponse: nonisolated Codable, Sendable {
    let drafts: [StudyManualCardDraft]
    let total: Int?
    let limit: Int
    let nextCursor: String?
}

struct CreateStudyManualCardDraftRequest: Codable, Equatable, Sendable {
    let id: String
    let creationKind: StudyCardCreationKind
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let imagePlacement: StudyCardDraft.ImagePlacement
    let imagePrompt: String?
}

struct UpdateStudyManualCardDraftRequest: Encodable, Equatable, Sendable {
    let prompt: JSONValue
    let answer: JSONValue
    let imagePlacement: StudyCardDraft.ImagePlacement
    let imagePrompt: String?
    let previewAudio: JSONValue
    let previewAudioRole: JSONValue
    let previewImage: JSONValue
}

struct StudyCardDraftPreviewAudioResponse: nonisolated Codable, Sendable {
    let previewAudio: JSONValue?
    let previewAudioRole: String?
}

struct StudyCardDraftImageResponse: nonisolated Codable, Sendable {
    let previewImage: JSONValue
    let imagePrompt: String
    let imagePlacement: StudyCardDraft.ImagePlacement
}

struct CreateCardFromStudyManualDraftRequest: Codable, Equatable, Sendable {
    let id: String
}

struct StudySession: nonisolated Codable, Sendable {
    let overview: StudyOverview
    let cards: [StudyCard]
}

struct StudySessionResponse: nonisolated Decodable, Sendable {
    let session: StudySession

    private enum CodingKeys: String, CodingKey {
        case data
        case overview
        case cards
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.data) {
            session = try container.decode(StudySession.self, forKey: .data)
        } else {
            session = try StudySession(from: decoder)
        }
    }
}

struct StudyOfflineReserve: nonisolated Decodable, Sendable {
    let cards: [StudyCard]
    let reserveDays: Int
    let generatedAt: Date
    let horizonEndsAt: Date

    enum CodingKeys: String, CodingKey {
        // The Study compatibility controller emits these fields in camel case.
        case cards
        case reserveDays = "reserveDays"
        case generatedAt = "generatedAt"
        case horizonEndsAt = "horizonEndsAt"
    }

    var metadata: StudyOfflineReserveMetadata {
        StudyOfflineReserveMetadata(
            reserveDays: reserveDays,
            generatedAt: generatedAt,
            horizonEndsAt: horizonEndsAt
        )
    }
}

struct StudyOfflineReserveMetadata: nonisolated Codable, Equatable, Sendable {
    let reserveDays: Int
    let generatedAt: Date
    let horizonEndsAt: Date
}

struct SyncFeedPage: nonisolated Decodable, Sendable {
    struct Entry: nonisolated Decodable, Sendable {
        let checkpoint: Int64
        let resourceId: String
        let operation: String

        enum CodingKeys: String, CodingKey {
            case checkpoint, operation
            case resourceId = "resource_id"
        }
    }

    struct Metadata: nonisolated Decodable, Sendable {
        let nextCheckpoint: Int64
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case nextCheckpoint = "next_checkpoint"
            case hasMore = "has_more"
        }
    }

    let data: [Entry]
    let meta: Metadata
}

struct StudyCardBatchRequest: Encodable, Sendable {
    let ids: [String]
}

struct StudyCardBatchResponse: nonisolated Decodable, Sendable {
    let cards: [StudyCard]
}

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

struct StudyCardPresentationV1: nonisolated Codable, Hashable, Sendable {
    struct MediaReference: nonisolated Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case id
            case filename
            case url
            case mediaKind
            case source
        }

        let id: String?
        let filename: String?
        let url: String?
        let mediaKind: String?
        let source: String?

        nonisolated init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            filename = try container.decodeIfPresent(String.self, forKey: .filename)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            mediaKind = try container.decodeIfPresent(String.self, forKey: .mediaKind)
            source = try container.decodeIfPresent(String.self, forKey: .source)
        }
    }

    struct PitchAccent: nonisolated Codable, Hashable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case status
            case expression
            case reading
            case pitchNum
            case morae
            case pattern
            case patternName
            case source
            case resolvedBy
        }

        // A v1 pitch payload is present only after server resolution; other statuses
        // are contract drift and intentionally fail the known-version decode.
        private enum Status: String, nonisolated Codable {
            case resolved
        }

        private let status: Status
        let expression: String
        let reading: String
        let pitchNum: Int?
        let morae: [String]
        let pattern: [Int]
        let patternName: String
        let source: String?
        let resolvedBy: String?

        nonisolated init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            expression = try container.decode(String.self, forKey: .expression)
            reading = try container.decode(String.self, forKey: .reading)
            pitchNum = try container.decodeIfPresent(Int.self, forKey: .pitchNum)
            morae = try container.decode([String].self, forKey: .morae)
            pattern = try container.decode([Int].self, forKey: .pattern)
            patternName = try container.decode(String.self, forKey: .patternName)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)

            guard
                !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !patternName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !morae.isEmpty,
                morae.count == pattern.count,
                morae.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }),
                pattern.allSatisfy({ $0 == 0 || $0 == 1 })
            else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Resolved pitch accent was malformed."
                ))
            }
        }
    }

    struct Front: nonisolated Codable, Hashable, Sendable {
        enum Mode: String, nonisolated Codable, Hashable, Sendable {
            case text
            case media
            case cloze
        }

        struct Media: nonisolated Codable, Hashable, Sendable {
            let audio: MediaReference?
            let image: MediaReference?
        }

        let mode: Mode
        let text: String?
        let ruby: String?
        let hint: String?
        let media: Media
        let autoplayAudio: Bool
    }

    struct Answer: nonisolated Codable, Hashable, Sendable {
        struct Text: nonisolated Codable, Hashable, Sendable {
            let text: String?
            let ruby: String?
        }

        struct Sentences: nonisolated Codable, Hashable, Sendable {
            let japanese: Text
            let english: Text
        }

        struct Media: nonisolated Codable, Hashable, Sendable {
            let image: MediaReference?
        }

        let heading: String?
        let ruby: String?
        let restored: String?
        let meaning: String?
        let sentences: Sentences
        let notes: [String]
        let media: Media
        let audio: MediaReference?
        let pitchAccent: PitchAccent?
    }

    let version: Int
    let front: Front
    let answer: Answer
}

struct StudyCard: nonisolated Codable, Identifiable, Hashable, Sendable {
    private struct PresentationVersion: nonisolated Decodable {
        let version: Int
    }

    struct State: nonisolated Codable, Hashable, Sendable {
        let dueAt: Date?
        let introducedAt: Date?
        let failedAt: Date?
        let queueState: String
        let scheduler: JSONValue?
        let source: JSONValue
    }

    private struct ProgressionFieldPresence: nonisolated Hashable, Sendable {
        let variantGroupId: Bool
        let variantStatus: Bool

        // Payload field presence affects compatibility reconciliation, not the
        // semantic identity of an otherwise identical card.
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

        nonisolated func hash(into hasher: inout Hasher) {}
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case syncId
        case noteId
        case revision
        case cardType
        case prompt
        case answer
        case presentation
        case state
        case answerAudioSource
        case masteryLevel
        case variantGroupId
        case variantStatus
        case introductionCohortId
        case selectionPolicy
        case priorityUntil
        case introductionAvailableAt
        case createdAt
        case updatedAt
    }

    let id: String
    let syncId: String?
    let noteId: String?
    // Nil only for payloads cached before the revision contract shipped.
    let revision: Int?
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let serverPresentation: StudyCardPresentationV1?
    let state: State
    let answerAudioSource: String?
    let masteryLevel: String?
    let variantGroupId: String?
    let variantStatus: String?
    let introductionCohortId: String?
    let selectionPolicy: String?
    let priorityUntil: Date?
    let introductionAvailableAt: Date?
    let createdAt: Date
    let updatedAt: Date
    private let progressionFieldPresence: ProgressionFieldPresence

    init(
        id: String,
        syncId: String? = nil,
        noteId: String?,
        revision: Int? = nil,
        cardType: String,
        prompt: JSONValue,
        answer: JSONValue,
        serverPresentation: StudyCardPresentationV1? = nil,
        state: State,
        answerAudioSource: String?,
        masteryLevel: String? = nil,
        variantGroupId: String? = nil,
        variantStatus: String? = nil,
        introductionCohortId: String? = nil,
        selectionPolicy: String? = nil,
        priorityUntil: Date? = nil,
        introductionAvailableAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.syncId = syncId
        self.noteId = noteId
        self.revision = revision
        self.cardType = cardType
        self.prompt = prompt
        self.answer = answer
        self.serverPresentation = serverPresentation
        self.state = state
        self.answerAudioSource = answerAudioSource
        self.masteryLevel = masteryLevel
        self.variantGroupId = variantGroupId
        self.variantStatus = variantStatus
        self.introductionCohortId = introductionCohortId
        self.selectionPolicy = selectionPolicy
        self.priorityUntil = priorityUntil
        self.introductionAvailableAt = introductionAvailableAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        progressionFieldPresence = .init(
            variantGroupId: true,
            variantStatus: true
        )
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId)
        noteId = try container.decodeIfPresent(String.self, forKey: .noteId)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        cardType = try container.decode(String.self, forKey: .cardType)
        prompt = try container.decode(JSONValue.self, forKey: .prompt)
        answer = try container.decode(JSONValue.self, forKey: .answer)
        if let version = try container.decodeIfPresent(
            PresentationVersion.self,
            forKey: .presentation
        ), version.version == 1 {
            serverPresentation = try container.decode(
                StudyCardPresentationV1.self,
                forKey: .presentation
            )
        } else {
            // Missing and future presentation versions intentionally use the raw
            // prompt/answer compatibility renderer.
            serverPresentation = nil
        }
        state = try container.decode(State.self, forKey: .state)
        answerAudioSource = try container.decodeIfPresent(
            String.self,
            forKey: .answerAudioSource
        )
        masteryLevel = try container.decodeIfPresent(String.self, forKey: .masteryLevel)
        variantGroupId = try container.decodeIfPresent(String.self, forKey: .variantGroupId)
        variantStatus = try container.decodeIfPresent(String.self, forKey: .variantStatus)
        introductionCohortId = try container.decodeIfPresent(
            String.self,
            forKey: .introductionCohortId
        )
        selectionPolicy = try container.decodeIfPresent(String.self, forKey: .selectionPolicy)
        priorityUntil = try container.decodeIfPresent(Date.self, forKey: .priorityUntil)
        introductionAvailableAt = try container.decodeIfPresent(
            Date.self,
            forKey: .introductionAvailableAt
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        progressionFieldPresence = .init(
            variantGroupId: container.contains(.variantGroupId),
            variantStatus: container.contains(.variantStatus)
        )
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(syncId, forKey: .syncId)
        try container.encodeIfPresent(noteId, forKey: .noteId)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encode(cardType, forKey: .cardType)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(answer, forKey: .answer)
        try container.encodeIfPresent(serverPresentation, forKey: .presentation)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(answerAudioSource, forKey: .answerAudioSource)
        try container.encodeIfPresent(masteryLevel, forKey: .masteryLevel)
        try container.encode(variantGroupId, forKey: .variantGroupId)
        try container.encode(variantStatus, forKey: .variantStatus)
        try container.encodeIfPresent(introductionCohortId, forKey: .introductionCohortId)
        try container.encodeIfPresent(selectionPolicy, forKey: .selectionPolicy)
        try container.encodeIfPresent(priorityUntil, forKey: .priorityUntil)
        try container.encodeIfPresent(
            introductionAvailableAt,
            forKey: .introductionAvailableAt
        )
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var reviewCardID: String { syncId ?? id }

    func resolvedVariantGroupId(fallingBackTo fallback: String?) -> String? {
        progressionFieldPresence.variantGroupId ? variantGroupId : fallback
    }

    func resolvedVariantStatus(fallingBackTo fallback: String?) -> String? {
        progressionFieldPresence.variantStatus ? variantStatus : fallback
    }

    var includesProgressionMetadataProjection: Bool {
        progressionFieldPresence.variantGroupId && progressionFieldPresence.variantStatus
    }

    func resolvingProgressionMetadata(fallingBackTo fallback: StudyCard) -> Self {
        guard !includesProgressionMetadataProjection else { return self }
        return Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
            variantGroupId: resolvedVariantGroupId(fallingBackTo: fallback.variantGroupId),
            variantStatus: resolvedVariantStatus(fallingBackTo: fallback.variantStatus),
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func replacingIdentity(id: String, syncId: String?) -> Self {
        Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
            variantGroupId: variantGroupId,
            variantStatus: variantStatus,
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func replacingVariantStatus(_ variantStatus: String?) -> Self {
        Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
            variantGroupId: variantGroupId,
            variantStatus: variantStatus,
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    var promptText: String {
        if let heading = presentation.front.heading {
            return StudyRubyDocument.parse(heading, knownKanji: []).plainText
        }
        if cardType == "cloze" {
            return "Study card"
        }
        if presentation.front.audioURL != nil || presentation.front.imageURL != nil {
            return presentation.back.heading
                ?? presentation.back.textBlocks.first { $0.role == .meaning }?.text
                ?? "Media prompt"
        }
        return prompt.preferredText ?? answer.preferredText ?? "Study card"
    }

    var answerText: String {
        if serverPresentation != nil, cardType != "cloze" {
            return presentation.back.textBlocks.first { $0.role == .meaning }?.text
                ?? presentation.back.heading.map {
                    StudyRubyDocument.parse($0, knownKanji: []).plainText
                }
                ?? "No answer text"
        }
        if cardType == "cloze" {
            return presentation.back.heading.map {
                StudyRubyDocument.parse($0, knownKanji: []).plainText
            }
                ?? answer.firstNonEmptyString(for: ["restoredText", "expression", "text", "meaning"])
                ?? answer.preferredText
                ?? "No answer text"
        }
        return answer.firstNonEmptyString(for: ["meaning", "translation", "text", "answerText"])
            ?? answer.preferredText
            ?? "No answer text"
    }

    var answerDetailText: String? {
        guard cardType == "cloze" else { return nil }
        if serverPresentation != nil {
            let detail = presentation.back.textBlocks.first { $0.role == .meaning }?.text
            return detail == answerText ? nil : detail
        }
        let detail = answer.firstNonEmptyString(for: ["meaning", "translation"])
        return detail == answerText ? nil : detail
    }

    var mediaURLs: [URL] {
        guard serverPresentation != nil else {
            return prompt.mediaURLs + answer.mediaURLs
        }
        let projected = presentation
        return [
            projected.front.audioURL,
            projected.front.imageURL,
            projected.back.audioURL,
            projected.back.imageURL,
        ].compactMap(\.self)
    }

    func reviewSchedule(
        _ rating: ReviewRating,
        at reviewedAt: Date
    ) throws -> FSRSReviewSchedule {
        try FSRSReviewScheduler.schedule(
            schedulerState: state.scheduler,
            queueState: state.queueState,
            rating: rating,
            reviewedAt: reviewedAt
        )
    }

    func applyingReview(_ rating: ReviewRating, at reviewedAt: Date) throws -> StudyCard {
        let schedule = try reviewSchedule(rating, at: reviewedAt)
        return StudyCard(
            id: id,
            syncId: syncId,
            noteId: noteId,
            revision: revision,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            serverPresentation: serverPresentation,
            state: .init(
                dueAt: schedule.dueAt,
                introducedAt: state.introducedAt
                    ?? (state.queueState == "new" ? reviewedAt : nil),
                failedAt: rating == .again ? reviewedAt : nil,
                queueState: schedule.queueState,
                scheduler: schedule.schedulerState,
                source: state.source
            ),
            answerAudioSource: answerAudioSource,
            variantGroupId: variantGroupId,
            variantStatus: variantStatus,
            introductionCohortId: introductionCohortId,
            selectionPolicy: selectionPolicy,
            priorityUntil: priorityUntil,
            introductionAvailableAt: introductionAvailableAt,
            createdAt: createdAt,
            updatedAt: reviewedAt
        )
    }

    func isEligibleForOfflineStudy(at date: Date) -> Bool {
        guard isProgressionAvailable else { return false }
        guard ["learning", "review", "relearning"].contains(state.queueState) else {
            return false
        }
        guard let dueAt = state.dueAt else { return false }
        return dueAt <= date
    }

    var belongsToLearningProgression: Bool {
        variantGroupId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var isProgressionAvailable: Bool {
        variantStatus == nil
            || variantStatus?.localizedCaseInsensitiveCompare("available") == .orderedSame
    }
}

struct StudyNewCardQueueItem: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let noteId: String
    let cardType: String
    let displayText: String
    let meaning: String?
    let queuePosition: Int?
    let createdAt: Date
    let updatedAt: Date
}

struct StudyNewCardQueueResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyNewCardQueueItem]
    let total: Int
    let limit: Int
    let nextCursor: String?
}

struct StudyIntroductionCohort: nonisolated Codable, Equatable, Sendable {
    let id: String
    let sourceKind: String
    let label: String?
    let priorityUntil: Date
    let cards: [StudyCard]
    let createdAt: Date
    let updatedAt: Date
}

struct CreateStudyLessonFollowupCohortRequest: nonisolated Encodable, Equatable, Sendable {
    let cohortId: String
    let cardIds: [String]
    let label: String?
}

struct StudyCardListResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyCard]
    let limit: Int
    let nextCursor: String?
}

enum StudyLearningItemStageStatus: String, nonisolated Codable, Equatable, Sendable {
    case locked
    case available
    case retired
    case unknown

    nonisolated init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum StudyLearningPathUnlockRequirement: String, nonisolated Codable, Equatable, Hashable, Sendable {
    case successfulRetrieval = "successful_retrieval"
    case guru
    case master
    case unknown

    nonisolated init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static var selectableCases: [Self] {
        [.successfulRetrieval, .guru, .master]
    }

    var title: String {
        switch self {
        case .successfulRetrieval: "2 successful reviews"
        case .guru: "Guru"
        case .master: "Master"
        case .unknown: "Unknown"
        }
    }

    var helpText: String {
        switch self {
        case .successfulRetrieval:
            "Unlock after two Good or Easy reviews."
        case .guru:
            "Unlock once this card reaches Guru and the next review is Good or Easy."
        case .master:
            "Unlock once this card reaches Master and the next review is Good or Easy."
        case .unknown:
            "This path uses a requirement added by a newer version of ConvoLab."
        }
    }
}

struct StudyLearningPathCard: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sourceNoteId: String?
    let cardType: String
    let frontText: String?
    let backText: String?
    let promptJSON: JSONValue?
    let answerJSON: JSONValue?
    let variantStage: Int?
    let variantStatus: StudyLearningItemStageStatus?
    let variantUnlockRequirement: StudyLearningPathUnlockRequirement?

    enum CodingKeys: String, CodingKey {
        case id
        case sourceNoteId = "source_note_id"
        case cardType = "card_type"
        case frontText = "front_text"
        case backText = "back_text"
        case promptJSON = "prompt_json"
        case answerJSON = "answer_json"
        case variantStage = "variant_stage"
        case variantStatus = "variant_status"
        case variantUnlockRequirement = "variant_unlock_requirement"
    }

    var displayText: String {
        promptJSON?.firstNonEmptyString(
            for: ["clozeDisplayText", "cueText", "clozeText", "text"]
        ) ?? normalized(frontText) ?? id
    }

    var meaning: String? {
        answerJSON?.firstNonEmptyString(
            for: ["meaning", "translation", "sentenceEn", "text"]
        ) ?? normalized(backText)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct StudyLearningPathStage: nonisolated Codable, Identifiable, Equatable, Sendable {
    let number: Int?
    let cards: [StudyLearningPathCard]

    nonisolated var id: String {
        number.map { "stage:\($0)" }
            ?? "cards:\(cards.map(\.id).joined(separator: ","))"
    }
}

struct StudyLearningPath: nonisolated Codable, Equatable, Sendable {
    let groupId: String?
    let anchorCardId: String
    let stages: [StudyLearningPathStage]

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case anchorCardId = "anchor_card_id"
        case stages
    }
}

struct LinkStudyLearningPathSuccessorRequest: Encodable, Equatable, Sendable {
    let successorCardId: String
    let unlockRequirement: StudyLearningPathUnlockRequirement

    enum CodingKeys: String, CodingKey {
        case successorCardId = "successor_card_id"
        case unlockRequirement = "unlock_requirement"
    }
}

struct StudyLearningItemCard: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let syncId: String
    let noteId: String?
    let cardType: String
    let displayText: String
    let meaning: String?
    let variantKind: String?
}

struct StudyLearningItemStage: nonisolated Codable, Identifiable, Equatable, Sendable {
    let number: Int?
    let status: StudyLearningItemStageStatus?
    let cardCount: Int
    let representativeCard: StudyLearningItemCard
    let cards: [StudyLearningItemCard]

    nonisolated var id: String {
        number.map { "stage:\($0)" }
            ?? "card:\(representativeCard.syncId.lowercased())"
    }
}

struct StudyLearningItem: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String
    let groupId: String?
    let representativeCard: StudyLearningItemCard
    let currentStageNumber: Int?
    let stageCount: Int
    let cardCount: Int
    let retiredStageCount: Int
    let transferDemonstrated: Bool
    let stages: [StudyLearningItemStage]
}

struct StudyLearningItemListResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyLearningItem]
    let limit: Int
    let nextCursor: String?
}

struct ReorderStudyNewCardQueueRequest: Encodable, Equatable, Sendable {
    let cardIds: [String]
}

enum ReviewRating: String, Codable, CaseIterable, Sendable {
    case again
    case hard
    case good
    case easy
}

struct ReviewBatchRequest: Codable {
    struct Event: Codable {
        let id: String
        let cardID: String
        let rating: ReviewRating
        let reviewedAt: Date
        let durationMilliseconds: Int?
        let clientEventID: String
        let deviceID: String
        let clientCreatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id, rating
            case cardID = "card_id"
            case reviewedAt = "reviewed_at"
            case durationMilliseconds = "duration_ms"
            case clientEventID = "client_event_id"
            case deviceID = "device_id"
            case clientCreatedAt = "client_created_at"
        }

        func encode(to encoder: Encoder) throws {
            // Review dates bypass APIClient's whole-second strategy so the wire
            // event retains the same canonical instant as the local projection.
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(cardID, forKey: .cardID)
            try container.encode(rating, forKey: .rating)
            try container.encode(
                ISO8601Milliseconds.string(from: reviewedAt),
                forKey: .reviewedAt
            )
            try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
            try container.encode(clientEventID, forKey: .clientEventID)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(
                ISO8601Milliseconds.string(from: clientCreatedAt),
                forKey: .clientCreatedAt
            )
        }
    }

    let events: [Event]
}

struct StudyMediaBatchRequest: Encodable {
    let ids: [String]
}

struct StudyMediaBatchResponse: nonisolated Decodable, Sendable {
    struct Item: nonisolated Decodable, Sendable {
        let id: String
        let mimeType: String
        let data: Data
    }

    let items: [Item]
}

struct UndoStudyReviewRequest: Encodable {
    let reviewLogId: String
    let timeZone: String
}

struct UndoStudyReviewResponse: nonisolated Decodable, Sendable {
    let reviewLogId: String
    let card: StudyCard
    let overview: StudyOverview
}

enum StudyCardActionName: String, nonisolated Codable, Sendable {
    case suspend
    case unsuspend
    case forget
    case setDue = "set_due"
}

enum StudyCardSetDueMode: String, nonisolated Codable, Sendable {
    case now
    case tomorrow
    case customDate = "custom_date"
}

struct StudyCardActionRequest: Codable, Equatable, Sendable {
    let action: StudyCardActionName
    let mode: StudyCardSetDueMode?
    let dueAt: Date?
    let timeZone: String?
}

struct StudyCardActionResponse: nonisolated Codable, Sendable {
    let card: StudyCard
    let overview: StudyOverview
}

struct DailyAudioPractice: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let practiceDate: String
    let status: String
    let targetDurationMinutes: Int
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let tracks: [DailyAudioTrack]
}

struct DailyAudioPracticePage: nonisolated Codable, Sendable {
    let items: [DailyAudioPractice]
    let total: Int
    let limit: Int
    let nextCursor: String?

    init(
        items: [DailyAudioPractice],
        total: Int,
        limit: Int,
        nextCursor: String?
    ) {
        self.items = items
        self.total = total
        self.limit = limit
        self.nextCursor = nextCursor
    }

    nonisolated init(from decoder: Decoder) throws {
        if var legacy = try? decoder.unkeyedContainer() {
            var practices: [DailyAudioPractice] = []
            while !legacy.isAtEnd {
                practices.append(try legacy.decode(DailyAudioPractice.self))
            }
            items = practices
            total = practices.count
            limit = practices.count
            nextCursor = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([DailyAudioPractice].self, forKey: .items)
        total = try container.decode(Int.self, forKey: .total)
        limit = try container.decode(Int.self, forKey: .limit)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct DailyAudioTrack: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let practiceId: String
    let mode: String
    let status: String
    let title: String
    let sortOrder: Int
    let scriptUnitsJson: [DailyAudioScriptUnit]?
    let audioUrl: String?
    let timingData: [DailyAudioTiming]?
    let approxDurationSeconds: Double?
    let updatedAt: Date

    var formattedDuration: String {
        guard let approxDurationSeconds,
              approxDurationSeconds.isFinite,
              approxDurationSeconds >= 0
        else {
            return "Length unavailable"
        }
        let roundedSeconds = Int(approxDurationSeconds.rounded())
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    var revisionMilliseconds: Int64 {
        Int64((updatedAt.timeIntervalSince1970 * 1_000).rounded())
    }

    static func latest(
        matching track: DailyAudioTrack,
        in practices: [DailyAudioPractice]
    ) -> DailyAudioTrack {
        practices.lazy.flatMap(\.tracks).first { $0.id == track.id } ?? track
    }

    init(
        id: String,
        practiceId: String,
        mode: String,
        status: String,
        title: String,
        sortOrder: Int,
        scriptUnitsJson: [DailyAudioScriptUnit]? = nil,
        audioUrl: String?,
        timingData: [DailyAudioTiming]? = nil,
        approxDurationSeconds: Double?,
        updatedAt: Date
    ) {
        self.id = id
        self.practiceId = practiceId
        self.mode = mode
        self.status = status
        self.title = title
        self.sortOrder = sortOrder
        self.scriptUnitsJson = scriptUnitsJson
        self.audioUrl = audioUrl
        self.timingData = timingData
        self.approxDurationSeconds = approxDurationSeconds
        self.updatedAt = updatedAt
    }
}

struct DailyAudioScriptUnit: nonisolated Codable, Equatable, Sendable {
    let type: String
    let text: String?
    let reading: String?
    let translation: String?

    nonisolated init(
        type: String,
        text: String?,
        reading: String?,
        translation: String?
    ) {
        self.type = type
        self.text = text
        self.reading = reading
        self.translation = translation
    }
}

struct DailyAudioTiming: nonisolated Codable, Equatable, Sendable {
    let unitIndex: Int
    let startTime: Double
    let endTime: Double

    nonisolated init(
        unitIndex: Int,
        startTime: Double,
        endTime: Double
    ) {
        self.unitIndex = unitIndex
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct CreateDailyAudioRequest: Encodable {
    let timeZone: String
    let targetDurationMinutes: Int
}

struct CreateStudyCardRequest: Codable {
    let id: String
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
}

struct UpdateStudyCardRequest: Codable {
    let prompt: JSONValue
    let answer: JSONValue
    // Nil preserves legacy queued edits as unconditional writes; newly projected
    // edits from authoritative cards always carry the server revision.
    let expectedRevision: Int?

    private enum CodingKeys: String, CodingKey {
        case prompt
        case answer
        case expectedRevision
    }

    init(
        prompt: JSONValue,
        answer: JSONValue,
        expectedRevision: Int? = nil
    ) {
        self.prompt = prompt
        self.answer = answer
        self.expectedRevision = expectedRevision
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try container.decode(JSONValue.self, forKey: .prompt)
        answer = try container.decode(JSONValue.self, forKey: .answer)
        // Outbox rows written by earlier app versions predate optimistic revisions.
        // Preserve that as unknown so the backend can accept the legacy edit
        // without mistaking a migration artifact for a concurrent write.
        expectedRevision = try container.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }
}

struct KnownKanjiSnapshot: nonisolated Codable, Equatable, Sendable {
    struct WaniKaniStatus: nonisolated Codable, Equatable, Sendable {
        struct TransferBridgeStatus: nonisolated Codable, Equatable, Sendable {
            let enabled: Bool
            let importedVocabularyCount: Int
            let pendingVocabularyCount: Int
            let failedVocabularyCount: Int
            let lastImportedAt: Date?

            static let disabled = TransferBridgeStatus(
                enabled: false,
                importedVocabularyCount: 0,
                pendingVocabularyCount: 0,
                failedVocabularyCount: 0,
                lastImportedAt: nil
            )
        }

        let connected: Bool
        let lastSyncedAt: Date?
        let reviewCount: Int?
        let reviewCountUpdatedAt: Date?
        let transferBridge: TransferBridgeStatus?

        init(
            connected: Bool,
            lastSyncedAt: Date?,
            reviewCount: Int? = nil,
            reviewCountUpdatedAt: Date? = nil,
            transferBridge: TransferBridgeStatus? = nil
        ) {
            self.connected = connected
            self.lastSyncedAt = lastSyncedAt
            self.reviewCount = reviewCount
            self.reviewCountUpdatedAt = reviewCountUpdatedAt
            self.transferBridge = transferBridge
        }
    }

    let version: Int
    let kanji: [String]
    let manualKanji: [String]
    let wanikani: WaniKaniStatus
}

struct ConnectWaniKaniRequest: Encodable {
    let apiToken: String
}

struct UpdateWaniKaniTransferBridgeRequest: Encodable {
    let enabled: Bool
}

struct WaniKaniSyncResult: nonisolated Decodable, Equatable, Sendable {
    let added: Int
    let effectiveTotal: Int
    let version: Int
}
