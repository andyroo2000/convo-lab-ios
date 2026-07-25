import Foundation

struct APIEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

struct CurrentUser: Codable, Sendable {
    let id: Int
    let name: String
    let email: String
    let emailVerifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, email
        case emailVerifiedAt = "email_verified_at"
    }
}

struct MobileTokenResponse: Decodable {
    struct TokenData: Decodable {
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
        case name, email, password, inviteCode
        case deviceName = "device_name"
    }
}

struct RegistrationResponse: Decodable {
    struct RegistrationData: Decodable {
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

enum StudyCardCreationKind: String, Codable, CaseIterable, Identifiable, Sendable {
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
struct StudyManualCardDraft: Codable, Identifiable, Equatable, Sendable {
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

struct StudyManualCardDraftListResponse: Codable, Sendable {
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

struct StudyCardDraftPreviewAudioResponse: Codable, Sendable {
    let previewAudio: JSONValue?
    let previewAudioRole: String?
}

struct StudyCardDraftImageResponse: Codable, Sendable {
    let previewImage: JSONValue
    let imagePrompt: String
    let imagePlacement: StudyCardDraft.ImagePlacement
}

struct CreateCardFromStudyManualDraftRequest: Codable, Equatable, Sendable {
    let id: String
}

struct StudySession: Codable, Sendable {
    let overview: StudyOverview
    let cards: [StudyCard]
}

struct StudySessionResponse: Decodable, Sendable {
    let session: StudySession

    private enum CodingKeys: String, CodingKey {
        case data
        case overview
        case cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.data) {
            session = try container.decode(StudySession.self, forKey: .data)
        } else {
            session = try StudySession(from: decoder)
        }
    }
}

struct StudyOfflineReserve: Decodable, Sendable {
    let cards: [StudyCard]
    let reserveDays: Int
    let generatedAt: Date
    let horizonEndsAt: Date
}

struct SyncFeedPage: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let checkpoint: Int64
        let resourceId: String
        let operation: String

        enum CodingKeys: String, CodingKey {
            case checkpoint, operation
            case resourceId = "resource_id"
        }
    }

    struct Metadata: Decodable, Sendable {
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

struct StudyOverview: Codable, Sendable {
    let dueCount: Int
    let failedCount: Int?
    let newCount: Int
    let reviewCount: Int
    let newCardsPerDay: Int
    let newCardsAvailableToday: Int?

    init(
        dueCount: Int,
        newCount: Int,
        reviewCount: Int,
        newCardsPerDay: Int,
        newCardsAvailableToday: Int?,
        failedCount: Int? = nil
    ) {
        self.dueCount = dueCount
        self.failedCount = failedCount
        self.newCount = newCount
        self.reviewCount = reviewCount
        self.newCardsPerDay = newCardsPerDay
        self.newCardsAvailableToday = newCardsAvailableToday
    }

    private enum CodingKeys: String, CodingKey {
        case dueCount
        case failedCount
        case newCount
        case reviewCount
        case newCardsPerDay
        case newCardsAvailableToday

        case legacyDueCount = "due_count"
        case legacyFailedCount = "failed_count"
        case legacyNewCount = "new_count"
        case legacyReviewCount = "review_count"
        case legacyNewCardsPerDay = "new_cards_per_day"
        case legacyNewCardsAvailableToday = "new_cards_available_today"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dueCount = try container.decodeIfPresent(Int.self, forKey: .dueCount)
            ?? container.decode(Int.self, forKey: .legacyDueCount)
        failedCount = try container.decodeIfPresent(Int.self, forKey: .failedCount)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyFailedCount)
        newCount = try container.decodeIfPresent(Int.self, forKey: .newCount)
            ?? container.decode(Int.self, forKey: .legacyNewCount)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount)
            ?? container.decode(Int.self, forKey: .legacyReviewCount)
        newCardsPerDay = try container.decodeIfPresent(Int.self, forKey: .newCardsPerDay)
            ?? container.decode(Int.self, forKey: .legacyNewCardsPerDay)
        newCardsAvailableToday = try container.decodeIfPresent(Int.self, forKey: .newCardsAvailableToday)
            ?? container.decodeIfPresent(Int.self, forKey: .legacyNewCardsAvailableToday)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dueCount, forKey: .dueCount)
        try container.encodeIfPresent(failedCount, forKey: .failedCount)
        try container.encode(newCount, forKey: .newCount)
        try container.encode(reviewCount, forKey: .reviewCount)
        try container.encode(newCardsPerDay, forKey: .newCardsPerDay)
        try container.encodeIfPresent(newCardsAvailableToday, forKey: .newCardsAvailableToday)
    }
}

struct StudyCard: Codable, Identifiable, Hashable, Sendable {
    struct State: Codable, Hashable, Sendable {
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var reviewCardID: String { syncId ?? id }

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

    func reviewSchedule(_ rating: ReviewRating, at reviewedAt: Date) -> FSRSReviewSchedule {
        FSRSReviewScheduler.schedule(
            schedulerState: state.scheduler,
            queueState: state.queueState,
            rating: rating,
            reviewedAt: reviewedAt
        )
    }

    func applyingReview(_ rating: ReviewRating, at reviewedAt: Date) -> StudyCard {
        let schedule = reviewSchedule(rating, at: reviewedAt)
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
    }

    let events: [Event]
}

struct UndoStudyReviewRequest: Encodable {
    let reviewLogId: String
    let timeZone: String
    let currentOverview: StudyOverview?
}

struct UndoStudyReviewResponse: Decodable {
    let reviewLogId: String
    let card: StudyCard
    let overview: StudyOverview
}

struct DailyAudioPractice: Codable, Identifiable, Sendable {
    let id: String
    let practiceDate: String
    let status: String
    let targetDurationMinutes: Int
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
    let tracks: [DailyAudioTrack]
}

struct DailyAudioTrack: Codable, Identifiable, Sendable {
    let id: String
    let practiceId: String
    let mode: String
    let status: String
    let title: String
    let sortOrder: Int
    let audioUrl: String?
    let approxDurationSeconds: Double?
    let updatedAt: Date
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

struct KnownKanjiSnapshot: Codable, Equatable, Sendable {
    struct WaniKaniStatus: Codable, Equatable, Sendable {
        let connected: Bool
        let lastSyncedAt: Date?
    }

    let version: Int
    let kanji: [String]
    let manualKanji: [String]
    let wanikani: WaniKaniStatus
}

struct ConnectWaniKaniRequest: Encodable {
    let apiToken: String
}

struct WaniKaniSyncResult: Decodable, Equatable, Sendable {
    let added: Int
    let effectiveTotal: Int
    let version: Int
}
