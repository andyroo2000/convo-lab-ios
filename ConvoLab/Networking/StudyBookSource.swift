import Foundation

struct StudyBookSource: nonisolated Codable, Equatable, Sendable {
    var pileId: String
    var chapterId: String?
    var position: Int?
    var reference: String?
}

struct StudyCardPlacementSnapshot: nonisolated Decodable, Sendable {
    struct State: nonisolated Decodable, Sendable { let queueState: String }
    let id: String
    let syncId: String?
    let bookSource: StudyBookSource?
    let learnSoon: Bool?
    let state: State
}

struct StudyCardSourceAssignment: Encodable {
    let cardIds: [String]
    let bookSource: StudyBookSource?

    enum CodingKeys: String, CodingKey { case cardIds, bookSource }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cardIds, forKey: .cardIds)
        try container.encode(bookSource, forKey: .bookSource)
    }
}

struct StudyLearnSoonAssignment: Encodable {
    let cardIds: [String]
    let learnSoon: Bool
}
