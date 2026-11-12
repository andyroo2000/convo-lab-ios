import Foundation

nonisolated struct JournalEntry: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var title: String?
    var body: String
    var entryDate: String
    var version: Int
    let createdAt: String
    let updatedAt: String
}

nonisolated struct JournalSegment: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case plain, correction, optional, keep }
    let text: String
    let reading: String
    let kind: Kind
    let suggestion: String?
    let suggestionReading: String?
    let explanation: String?
    let explanationReading: String?
}

nonisolated struct JournalFeedback: Codable, Sendable, Equatable {
    let title: String
    let correctedText: String
    let correctedReading: String
    let question: String
    let questionReading: String
    let questionTranslation: String
    let segments: [JournalSegment]
    var entryText: String?
    var entryReading: String?
    var previousReading: String?
}

nonisolated enum JournalAnalysisStatus: String, Codable, Sendable {
    case queued, processing, ready, failed
    var isPending: Bool { self == .queued || self == .processing }
}

nonisolated struct JournalReply: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let parentId: String?
    let answer: String
    let status: JournalAnalysisStatus
    let result: JournalFeedback?
    let error: String?
}

nonisolated struct JournalAnalysis: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let sourceVersion: Int
    let status: JournalAnalysisStatus
    let result: JournalFeedback?
    let error: String?
    let updatedAt: String
    var replyRevision: Int?
    var currentReply: JournalReply?
    var pendingReplyId: String?

    var currentFeedback: JournalFeedback? { currentReply?.result ?? result }
    var correctedText: String? { currentReply?.result?.entryText ?? result?.correctedText }
    var correctedReading: String? { currentReply?.result?.entryReading ?? result?.correctedReading }
}

nonisolated struct JournalResource<Value: Codable & Sendable>: Codable, Sendable {
    let data: Value
}

nonisolated struct JournalArchivePage: Codable, Sendable {
    let data: [JournalEntry]
    let nextCursor: String?
}

nonisolated struct JournalAnalysisResponse: Codable, Sendable {
    let data: JournalAnalysis?
    let entry: JournalEntry
}

nonisolated struct JournalVoice: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}
