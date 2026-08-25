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
    let includesReviewTimeBudgetMinutes: Bool

    init(
        newCardsPerDay: Int,
        lessonBatchSize: Int = 5,
        reviewTimeBudgetMinutes: Int = 90,
        includesReviewTimeBudgetMinutes: Bool = true
    ) {
        self.newCardsPerDay = newCardsPerDay
        self.lessonBatchSize = lessonBatchSize
        self.reviewTimeBudgetMinutes = reviewTimeBudgetMinutes
        self.includesReviewTimeBudgetMinutes = includesReviewTimeBudgetMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case newCardsPerDay
        case lessonBatchSize
        case reviewTimeBudgetMinutes
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newCardsPerDay = try container.decode(Int.self, forKey: .newCardsPerDay)
        lessonBatchSize = try container.decodeIfPresent(Int.self, forKey: .lessonBatchSize) ?? 5
        reviewTimeBudgetMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .reviewTimeBudgetMinutes
        ) ?? 90
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
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.newCardsPerDay == rhs.newCardsPerDay
            && lhs.lessonBatchSize == rhs.lessonBatchSize
            && lhs.reviewTimeBudgetMinutes == rhs.reviewTimeBudgetMinutes
    }
}

struct UpdateStudySettingsRequest: Encodable, Equatable, Sendable {
    let newCardsPerDay: Int
    let lessonBatchSize: Int
    let reviewTimeBudgetMinutes: Int?

    private enum CodingKeys: String, CodingKey {
        case newCardsPerDay
        case lessonBatchSize
        case reviewTimeBudgetMinutes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(newCardsPerDay, forKey: .newCardsPerDay)
        try container.encode(lessonBatchSize, forKey: .lessonBatchSize)
        try container.encodeIfPresent(reviewTimeBudgetMinutes, forKey: .reviewTimeBudgetMinutes)
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

    func updatingReviewTimeBudget(to budgetMinutes: Int) -> Self {
        Self(
            recommendation: recommendation,
            readinessLevel: readinessLevel,
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

struct StudyCard: nonisolated Codable, Identifiable, Hashable, Sendable {
    struct State: nonisolated Codable, Hashable, Sendable {
        let dueAt: Date?
        let introducedAt: Date?
        let failedAt: Date?
        let queueState: String
        let scheduler: JSONValue?
        let source: JSONValue
    }

    let id: String
    let syncId: String?
    let noteId: String?
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let state: State
    let answerAudioSource: String?
    let masteryLevel: String?
    let createdAt: Date
    let updatedAt: Date

    init(
        id: String,
        syncId: String? = nil,
        noteId: String?,
        cardType: String,
        prompt: JSONValue,
        answer: JSONValue,
        state: State,
        answerAudioSource: String?,
        masteryLevel: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.syncId = syncId
        self.noteId = noteId
        self.cardType = cardType
        self.prompt = prompt
        self.answer = answer
        self.state = state
        self.answerAudioSource = answerAudioSource
        self.masteryLevel = masteryLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var reviewCardID: String { syncId ?? id }

    func replacingIdentity(id: String, syncId: String?) -> Self {
        Self(
            id: id,
            syncId: syncId,
            noteId: noteId,
            cardType: cardType,
            prompt: prompt,
            answer: answer,
            state: state,
            answerAudioSource: answerAudioSource,
            masteryLevel: masteryLevel,
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
        let detail = answer.firstNonEmptyString(for: ["meaning", "translation"])
        return detail == answerText ? nil : detail
    }

    var mediaURLs: [URL] { prompt.mediaURLs + answer.mediaURLs }

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
            cardType: cardType,
            prompt: prompt,
            answer: answer,
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
            createdAt: createdAt,
            updatedAt: reviewedAt
        )
    }

    func isEligibleForOfflineStudy(at date: Date) -> Bool {
        guard ["learning", "review", "relearning"].contains(state.queueState) else {
            return false
        }
        guard let dueAt = state.dueAt else { return false }
        return dueAt <= date
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

struct StudyCardListResponse: nonisolated Codable, Equatable, Sendable {
    let items: [StudyCard]
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
    let currentOverview: StudyOverview?
}

struct UndoStudyReviewResponse: nonisolated Decodable, Sendable {
    let reviewLogId: String
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
}

struct DailyAudioTiming: nonisolated Codable, Equatable, Sendable {
    let unitIndex: Int
    let startTime: Double
    let endTime: Double
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
}

struct KnownKanjiSnapshot: nonisolated Codable, Equatable, Sendable {
    struct WaniKaniStatus: nonisolated Codable, Equatable, Sendable {
        let connected: Bool
        let lastSyncedAt: Date?
        let reviewCount: Int?
        let reviewCountUpdatedAt: Date?

        init(
            connected: Bool,
            lastSyncedAt: Date?,
            reviewCount: Int? = nil,
            reviewCountUpdatedAt: Date? = nil
        ) {
            self.connected = connected
            self.lastSyncedAt = lastSyncedAt
            self.reviewCount = reviewCount
            self.reviewCountUpdatedAt = reviewCountUpdatedAt
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

struct WaniKaniSyncResult: nonisolated Decodable, Equatable, Sendable {
    let added: Int
    let effectiveTotal: Int
    let version: Int
}
