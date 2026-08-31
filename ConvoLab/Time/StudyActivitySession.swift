import Foundation

enum StudyActivityCategory: String, nonisolated Codable, CaseIterable, Identifiable, Sendable {
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

enum StudyActivityKind: String, nonisolated Codable, CaseIterable, Identifiable, Sendable {
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

enum StudyActivitySource: String, nonisolated Codable, Sendable {
    case automatic
    case manual
    case calendar
}

enum StudyActivityProvider: String, Equatable, Sendable {
    case googleCalendar = "google_calendar"
    case waniKani = "wanikani"
}

enum StudyActivityOrigin: String, nonisolated Codable, Sendable {
    case legacy
    case ios
    case web
    case googleCalendar = "google_calendar"
    case waniKani = "wanikani"
    case system

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

struct StudyActivitySession: nonisolated Codable, Identifiable, Equatable, Sendable {
    let id: String?
    let clientSessionId: String
    let category: StudyActivityCategory
    let activity: StudyActivityKind
    let source: StudyActivitySource
    let origin: StudyActivityOrigin
    let unknownOriginRawValue: String?
    let name: String?
    let startedAt: Date
    let endedAt: Date
    let durationMs: Int
    let audioPlaybackMs: Int?
    let cardsCreated: Int?

    var stableID: String { clientSessionId }
    var provider: StudyActivityProvider? { origin.provider }
    var hasUnknownOrigin: Bool { unknownOriginRawValue != nil }
    nonisolated var persistedOriginRawValue: String {
        unknownOriginRawValue ?? origin.rawValue
    }
    var isEditable: Bool {
        !hasUnknownOrigin && source != .automatic && origin.allowsUserEditing
    }

    /// Direct construction represents a new local event. Decoded legacy payloads
    /// take the compatibility path below and default a missing origin to legacy.
    nonisolated init(
        id: String?,
        clientSessionId: String,
        category: StudyActivityCategory,
        activity: StudyActivityKind,
        source: StudyActivitySource,
        origin: StudyActivityOrigin = .ios,
        unknownOriginRawValue: String? = nil,
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
        self.unknownOriginRawValue = unknownOriginRawValue
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

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        clientSessionId = try values.decode(String.self, forKey: .clientSessionId)
        activity = try values.decode(StudyActivityKind.self, forKey: .activity)
        category = try values.decodeIfPresent(StudyActivityCategory.self, forKey: .category)
            ?? activity.category
        source = try values.decode(StudyActivitySource.self, forKey: .source)
        // Missing/null identifies rows from before the origin contract. Provider
        // imports did not exist in that payload shape, and canonical responses
        // now always include origin, so only these legacy rows remain editable.
        if !values.contains(.origin) {
            origin = .legacy
            unknownOriginRawValue = nil
        } else if try values.decodeNil(forKey: .origin) {
            origin = .legacy
            unknownOriginRawValue = nil
        } else if let rawOrigin = try? values.decode(String.self, forKey: .origin) {
            origin = StudyActivityOrigin(rawValue: rawOrigin) ?? .legacy
            unknownOriginRawValue = StudyActivityOrigin(rawValue: rawOrigin) == nil
                ? rawOrigin
                : nil
        } else {
            origin = .legacy
            unknownOriginRawValue = "<invalid>"
        }
        name = try values.decodeIfPresent(String.self, forKey: .name)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decode(Date.self, forKey: .endedAt)
        durationMs = try values.decode(Int.self, forKey: .durationMs)
        audioPlaybackMs = try values.decodeIfPresent(Int.self, forKey: .audioPlaybackMs)
        cardsCreated = try values.decodeIfPresent(Int.self, forKey: .cardsCreated)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(id, forKey: .id)
        try values.encode(clientSessionId, forKey: .clientSessionId)
        try values.encode(category, forKey: .category)
        try values.encode(activity, forKey: .activity)
        try values.encode(source, forKey: .source)
        // The public API accepts only client-owned provenance. Legacy rows
        // omit origin so they remain editable without claiming a new owner.
        if origin == .ios || origin == .web {
            try values.encode(origin, forKey: .origin)
        }
        try values.encodeIfPresent(name, forKey: .name)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(endedAt, forKey: .endedAt)
        try values.encode(durationMs, forKey: .durationMs)
        try values.encodeIfPresent(audioPlaybackMs, forKey: .audioPlaybackMs)
        try values.encodeIfPresent(cardsCreated, forKey: .cardsCreated)
    }
}

struct StudyActivityBatchRequest: Encodable {
    let sessions: [StudyActivitySession]

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessions.map(WriteSession.init), forKey: .sessions)
    }

    private struct WriteSession: Encodable {
        let session: StudyActivitySession

        init(_ session: StudyActivitySession) {
            self.session = session
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(session.id, forKey: .id)
            try values.encode(session.clientSessionId, forKey: .clientSessionId)
            // learning-os derives category from activity.
            try values.encode(session.activity, forKey: .activity)
            try values.encode(session.source, forKey: .source)
            if session.origin == .ios || session.origin == .web {
                try values.encode(session.origin, forKey: .origin)
            }
            try values.encodeIfPresent(session.name, forKey: .name)
            try values.encode(session.startedAt, forKey: .startedAt)
            try values.encode(session.endedAt, forKey: .endedAt)
            try values.encode(session.durationMs, forKey: .durationMs)
            try values.encodeIfPresent(session.audioPlaybackMs, forKey: .audioPlaybackMs)
            try values.encodeIfPresent(session.cardsCreated, forKey: .cardsCreated)
        }

        private enum CodingKeys: String, CodingKey {
            case id, clientSessionId, activity, source, origin, name
            case startedAt, endedAt, durationMs, audioPlaybackMs, cardsCreated
        }
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
    }

}

struct EditableStudyActivitySessionPage: nonisolated Decodable, Equatable, Sendable {
    let items: [StudyActivitySession]
    let limit: Int
    let nextCursor: String?
}

enum StudyTimeRange: String, nonisolated Codable, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Day"
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

struct StudyTimeAnalytics: nonisolated Codable, Equatable, Sendable {
    let generatedAt: Date
    let anchorDate: String
    let timezone: String
    let ranges: [StudyTimeAnalyticsRange]

    func range(_ key: StudyTimeRange) -> StudyTimeAnalyticsRange? {
        ranges.first { $0.key == key }
    }
}

struct StudyTimeAnalyticsRange: nonisolated Codable, Equatable, Identifiable, Sendable {
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

struct StudyTimeAnalyticsBucket: nonisolated Codable, Equatable, Identifiable, Sendable {
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
