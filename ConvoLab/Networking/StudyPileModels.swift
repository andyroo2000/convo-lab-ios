import Foundation

struct StudyPileChapter: nonisolated Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let position: Int
    let isActive: Bool
    let sourceReference: String?
    let newCount: Int
    let readyCount: Int
    let introducedCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, position
        case isActive = "is_active"
        case sourceReference = "source_reference"
        case newCount = "new_count"
        case readyCount = "ready_count"
        case introducedCount = "introduced_count"
    }
}

struct StudyPile: nonisolated Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let position: Int
    let isActive: Bool
    let sourceReference: String?
    let newCount: Int
    let readyCount: Int
    let introducedCount: Int
    let chapters: [StudyPileChapter]

    enum CodingKeys: String, CodingKey {
        case id, title, position, chapters
        case isActive = "is_active"
        case sourceReference = "source_reference"
        case newCount = "new_count"
        case readyCount = "ready_count"
        case introducedCount = "introduced_count"
    }

    var summary: StudyPileChapter {
        StudyPileChapter(id: id, title: title, position: position, isActive: isActive,
                         sourceReference: sourceReference, newCount: newCount,
                         readyCount: readyCount, introducedCount: introducedCount)
    }
}

struct StudyPileCounts: nonisolated Codable, Sendable, Equatable {
    let newCount: Int
    let readyCount: Int
    let introducedCount: Int
    enum CodingKeys: String, CodingKey {
        case newCount = "new_count"
        case readyCount = "ready_count"
        case introducedCount = "introduced_count"
    }
}

struct StudyPileCatalog: nonisolated Codable, Sendable, Equatable {
    var piles: [StudyPile]
    let uncategorized: StudyPileCounts
    let learnSoon: StudyPileCounts
    let nextCursor: Int?
    enum CodingKeys: String, CodingKey {
        case piles, uncategorized
        case learnSoon = "learn_soon"
        case nextCursor = "next_cursor"
    }
}

struct StudyPileUpdate: nonisolated Encodable, Sendable {
    var title: String?
    var position: Int?
    var isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case title, position
        case isActive = "is_active"
    }
}
