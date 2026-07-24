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

struct PasswordResetRequest: Encodable {
    let email: String
}

struct StudySession: Codable, Sendable {
    let overview: StudyOverview
    let cards: [StudyCard]
}

struct StudyOverview: Codable, Sendable {
    let dueCount: Int
    let newCount: Int
    let reviewCount: Int
    let newCardsPerDay: Int
    let newCardsAvailableToday: Int?

    enum CodingKeys: String, CodingKey {
        case dueCount = "due_count"
        case newCount = "new_count"
        case reviewCount = "review_count"
        case newCardsPerDay = "new_cards_per_day"
        case newCardsAvailableToday = "new_cards_available_today"
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
    let noteId: String?
    let cardType: String
    let prompt: JSONValue
    let answer: JSONValue
    let state: State
    let answerAudioSource: String?
    let createdAt: Date
    let updatedAt: Date

    var promptText: String {
        if let heading = presentation.front.heading {
            return heading
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
            return presentation.back.heading
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
}

enum ReviewRating: String, Codable, CaseIterable, Sendable {
    case again
    case hard
    case good
    case easy

    var nextIntervalLabel: String {
        // Keep these synchronized with ApplyCardStudyReviewAction in learning-os.
        switch self {
        case .again: "<10m"
        case .hard: "1d"
        case .good: "3d"
        case .easy: "7d"
        }
    }
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
