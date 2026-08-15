import Foundation

enum StudyActivityCategory: String, Codable, CaseIterable, Identifiable {
    case review
    case listen
    case create
    case immerse
    case conversation
    case wanikani

    var id: String { rawValue }
    var title: String {
        switch self {
        case .review: "Card review"
        case .listen: "Listen"
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
        case .cardReview: .review
        case .dailyAudio: .listen
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

enum StudyActivityProvider: String, Equatable {
    case googleCalendar = "google_calendar"
    case waniKani = "wanikani"
}

enum StudyActivityOrigin: String, Codable {
    case legacy
    case ios
    case web
    case googleCalendar = "google_calendar"
    case waniKani = "wanikani"
    case system

    init(from decoder: Decoder) throws {
        // New server origins must not make an older client drop the whole ledger response.
        let container = try decoder.singleValueContainer()
        let value = try? container.decode(String.self)
        self = value.flatMap(Self.init(rawValue:)) ?? .legacy
    }

    var provider: StudyActivityProvider? {
        switch self {
        case .googleCalendar: .googleCalendar
        case .waniKani: .waniKani
        case .legacy, .ios, .web, .system: nil
        }
    }

    fileprivate var allowsUserEditing: Bool {
        switch self {
        case .legacy, .ios, .web: true
        case .googleCalendar, .waniKani, .system: false
        }
    }
}

struct StudyActivitySession: Codable, Identifiable, Equatable {
    let id: String?
    let clientSessionId: String
    let category: StudyActivityCategory
    let activity: StudyActivityKind
    let source: StudyActivitySource
    let origin: StudyActivityOrigin
    let name: String?
    let startedAt: Date
    let endedAt: Date
    let durationMs: Int
    let audioPlaybackMs: Int?
    let cardsCreated: Int?

    var stableID: String { clientSessionId }
    var provider: StudyActivityProvider? { origin.provider }
    var isEditable: Bool { source != .automatic && origin.allowsUserEditing }

    /// Direct construction represents a new local event. Decoded legacy payloads
    /// take the compatibility path below and default a missing origin to legacy.
    nonisolated init(
        id: String?,
        clientSessionId: String,
        category: StudyActivityCategory,
        activity: StudyActivityKind,
        source: StudyActivitySource,
        origin: StudyActivityOrigin = .ios,
        name: String?,
        startedAt: Date,
        endedAt: Date,
        durationMs: Int,
        audioPlaybackMs: Int?,
        cardsCreated: Int?
    ) {
        self.id = id
        self.clientSessionId = clientSessionId
        self.category = category
        self.activity = activity
        self.source = source
        self.origin = origin
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.audioPlaybackMs = audioPlaybackMs
        self.cardsCreated = cardsCreated
    }

    private enum CodingKeys: String, CodingKey {
        case id, clientSessionId, category, activity, source, origin, name
        case startedAt, endedAt, durationMs, audioPlaybackMs, cardsCreated
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        clientSessionId = try values.decode(String.self, forKey: .clientSessionId)
        category = try values.decode(StudyActivityCategory.self, forKey: .category)
        activity = try values.decode(StudyActivityKind.self, forKey: .activity)
        source = try values.decode(StudyActivitySource.self, forKey: .source)
        origin = try values.decodeIfPresent(StudyActivityOrigin.self, forKey: .origin)
            ?? .legacy
        name = try values.decodeIfPresent(String.self, forKey: .name)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decode(Date.self, forKey: .endedAt)
        durationMs = try values.decode(Int.self, forKey: .durationMs)
        audioPlaybackMs = try values.decodeIfPresent(Int.self, forKey: .audioPlaybackMs)
        cardsCreated = try values.decodeIfPresent(Int.self, forKey: .cardsCreated)
    }
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

    var drillDownTarget: StudyTimeRange? {
        switch self {
        case .year:
            .month
        case .week, .month:
            .today
        case .today, .all:
            nil
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

    func duration(for selectedCategories: Set<StudyActivityCategory>) -> Int {
        selectedCategories.reduce(0) { $0 + duration(for: $1) }
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

    func duration(for selectedCategories: Set<StudyActivityCategory>) -> Int {
        selectedCategories.reduce(0) { $0 + duration(for: $1) }
    }
}
