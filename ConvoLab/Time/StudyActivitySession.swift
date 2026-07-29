import Foundation

enum StudyActivityCategory: String, Codable, CaseIterable, Identifiable {
    case review
    case create
    case immerse

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum StudyActivityKind: String, Codable, CaseIterable, Identifiable {
    case cardReview = "card_review"
    case dailyAudio = "daily_audio"
    case cardCreation = "card_creation"
    case tv
    case podcast
    case reading
    case conversation
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cardReview: "Card reviews"
        case .dailyAudio: "Daily Audio"
        case .cardCreation: "Making cards"
        case .tv: "TV or film"
        case .podcast: "Podcast"
        case .reading: "Reading"
        case .conversation: "Conversation"
        case .other: "Other study"
        }
    }

    var category: StudyActivityCategory {
        switch self {
        case .cardReview, .dailyAudio: .review
        case .cardCreation: .create
        case .tv, .podcast, .reading, .conversation, .other: .immerse
        }
    }
}

enum StudyActivitySource: String, Codable {
    case automatic
    case manual
    case calendar
}

struct StudyActivitySession: Codable, Identifiable, Equatable {
    let id: String?
    let clientSessionId: String
    let category: StudyActivityCategory
    let activity: StudyActivityKind
    let source: StudyActivitySource
    let name: String?
    let startedAt: Date
    let endedAt: Date
    let durationMs: Int
    let audioPlaybackMs: Int?
    let cardsCreated: Int?

    var stableID: String { clientSessionId }
}

struct StudyActivityBatchRequest: Encodable {
    let sessions: [StudyActivitySession]
}
