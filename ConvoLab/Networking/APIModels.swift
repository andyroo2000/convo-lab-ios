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
    let newCount: Int
    let reviewCount: Int
    let newCardsPerDay: Int
    let newCardsAvailableToday: Int?

    enum CodingKeys: String, CodingKey {
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

    var promptText: String { prompt.preferredText ?? "Study card" }
    var answerText: String { answer.preferredText ?? "No answer text" }
    var mediaURLs: [URL] { prompt.mediaURLs + answer.mediaURLs }
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
