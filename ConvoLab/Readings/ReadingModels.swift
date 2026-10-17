import Foundation

struct ReadingSummary: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let author: String
    let revision: Int
    let pageCount: Int
    var pageNumbers: [Int]?
}

struct ReadingLibraryItem: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String
    var isBook: Bool { kind == "book" }
}

struct ReadingLibraryPage: nonisolated Codable, Sendable {
    let data: [ReadingLibraryItem]
    let currentPage: Int
    let lastPage: Int
    enum CodingKeys: String, CodingKey {
        case data
        case currentPage = "current_page"
        case lastPage = "last_page"
    }
}

struct ReadingBook: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let revision: Int
    let readings: [ReadingSummary]
}

struct ReadingDetail: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let revision: Int
    let document: ReadingDocument
    let voiceId: String
    let voiceName: String
    var illustrationUrl: String?
}

struct ReadingDocument: nonisolated Codable, Sendable {
    let title: String
    let author: String
    var authorReading: String?
    var illustrator: String?
    var tagline: String?
    let pages: [ReadingPage]
    let sentences: [ReadingSentence]
}

struct ReadingSentence: nonisolated Codable, Sendable {
    let text: String
    let translation: String
}

struct ReadingPage: nonisolated Codable, Sendable {
    let number: Int
    let kind: String
    let columns: [[ReadingSegment]]
    var notes: [ReadingSegment]?
    var biography: ReadingSegment?
    var imageUrl: String?
    var imageAspectRatio: Double?
    var imageCrop: ReadingImageCrop?
    var source: String?

    var sentenceIndices: [Int] {
        let parts = columns.flatMap { $0 } + (notes ?? []) + (biography.map { [$0] } ?? [])
        var seen = Set<Int>()
        return parts.map(\.index).filter { seen.insert($0).inserted }
    }
}

struct ReadingImageCrop: nonisolated Codable, Sendable {
    let left: Double
    let top: Double
    let width: Double
    let height: Double
}

struct ReadingSegment: nonisolated Codable, Sendable {
    let index: Int
    let text: String

    init(index: Int, text: String) {
        self.index = index
        self.text = text
    }

    nonisolated init(from decoder: any Decoder) throws {
        var values = try decoder.unkeyedContainer()
        index = try values.decode(Int.self)
        text = try values.decode(String.self)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(index)
        try values.encode(text)
    }
}

struct ReadingPosition: nonisolated Codable, Sendable {
    let readingId: String
    let pageNumber: Int
    let sentenceIndex: Int?
    let readingRevision: Int
    let eventId: String
    let readAt: Date

    nonisolated func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(readingId, forKey: .readingId)
        try values.encode(pageNumber, forKey: .pageNumber)
        try values.encode(sentenceIndex, forKey: .sentenceIndex)
        try values.encode(readingRevision, forKey: .readingRevision)
        try values.encode(eventId, forKey: .eventId)
        try values.encode(readAt, forKey: .readAt)
    }

    func isNewer(than other: Self) -> Bool {
        if readAt != other.readAt { return readAt > other.readAt }
        return eventId.lowercased() > other.eventId.lowercased()
    }
}

struct ReadingPositionResponse: nonisolated Decodable, Sendable {
    let position: ReadingPosition?
}

struct ReadingContinue: nonisolated Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let position: ReadingPosition
}

struct ReadingContinueResponse: nonisolated Decodable, Sendable {
    let `continue`: ReadingContinue?
}
