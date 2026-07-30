import Foundation

enum StudyActivityCategory: String, Codable, CaseIterable, Identifiable {
    case review
    case create
    case immerse
    case conversation
    case wanikani

    var id: String { rawValue }
    var title: String {
        switch self {
        case .review: "Card review"
        case .create: "Create"
        case .immerse: "Immerse"
        case .conversation: "Conversation"
        case .wanikani: "WaniKani"
        }
    }
}

enum StudyActivityKind: String, Codable, CaseIterable, Identifiable {
    case cardReview = "card_review"
    case dailyAudio = "daily_audio"
    case cardCreation = "card_creation"
    case tv
    case podcast
    case reading
    case conversation
    case wanikaniReview = "wanikani_review"
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
        case .wanikaniReview: "WaniKani reviews"
        case .other: "Other study"
        }
    }

    nonisolated var category: StudyActivityCategory {
        switch self {
        case .cardReview, .dailyAudio: .review
        case .cardCreation: .create
        case .tv, .podcast, .reading, .other: .immerse
        case .conversation: .conversation
        case .wanikaniReview: .wanikani
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

enum StudyTimeRange: String, Codable, CaseIterable, Identifiable {
    case today
    case week
    case month
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All"
        }
    }
}

struct StudyTimeAnalytics: Codable, Equatable {
    let generatedAt: Date
    let anchorDate: String
    let timezone: String
    let ranges: [StudyTimeAnalyticsRange]

    func range(_ key: StudyTimeRange) -> StudyTimeAnalyticsRange? {
        ranges.first { $0.key == key }
    }
}

struct StudyTimeAnalyticsRange: Codable, Equatable, Identifiable {
    let key: StudyTimeRange
    let startsAt: Date
    let endsAt: Date
    let totalMs: Int
    let categories: [String: Int]
    let buckets: [StudyTimeAnalyticsBucket]

    var id: StudyTimeRange { key }

    func duration(for category: StudyActivityCategory) -> Int {
        categories[category.rawValue, default: 0]
    }
}

struct StudyTimeAnalyticsBucket: Codable, Equatable, Identifiable {
    let startsAt: Date
    let endsAt: Date
    let totalMs: Int
    let categories: [String: Int]

    var id: Date { startsAt }

    func duration(for category: StudyActivityCategory) -> Int {
        categories[category.rawValue, default: 0]
    }
}
