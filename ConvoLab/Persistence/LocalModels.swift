import Foundation
import SwiftData

@Model
final class LocalCardRecord {
    @Attribute(.unique) var id: String
    var payload: Data
    var queueIndex: Int
    var isInActiveSession: Bool
    var mediaPreparedAt: Date?
    var serverUpdatedAt: Date
    var locallyUpdatedAt: Date?

    init(card: StudyCard, queueIndex: Int, payload: Data) {
        id = card.id
        self.payload = payload
        self.queueIndex = queueIndex
        isInActiveSession = true
        serverUpdatedAt = card.updatedAt
    }
}

@Model
final class PendingMutation {
    @Attribute(.unique) var id: String
    var kind: String
    var resourceID: String
    var payload: Data
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?

    init(kind: String, resourceID: String, payload: Data) {
        id = UUID().uuidString.lowercased()
        self.kind = kind
        self.resourceID = resourceID
        self.payload = payload
        createdAt = .now
        attemptCount = 0
    }
}

@Model
final class CachedMediaRecord {
    @Attribute(.unique) var remoteURL: String
    var relativePath: String
    var byteCount: Int64
    var lastAccessedAt: Date
    var category: String

    init(remoteURL: String, relativePath: String, byteCount: Int64, category: String) {
        self.remoteURL = remoteURL
        self.relativePath = relativePath
        self.byteCount = byteCount
        lastAccessedAt = .now
        self.category = category
    }
}

@Model
final class LocalDailyAudioPractice {
    @Attribute(.unique) var id: String
    var payload: Data
    var practiceDate: String
    var status: String
    var updatedAt: Date

    init(practice: DailyAudioPractice, payload: Data) {
        id = practice.id
        self.payload = payload
        practiceDate = practice.practiceDate
        status = practice.status
        updatedAt = practice.updatedAt
    }
}

@Model
final class LocalKnownKanjiSnapshot {
    @Attribute(.unique) var userID: Int
    var payload: Data
    var updatedAt: Date

    init(userID: Int, payload: Data, updatedAt: Date = .now) {
        self.userID = userID
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

enum Persistence {
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            LocalCardRecord.self,
            PendingMutation.self,
            CachedMediaRecord.self,
            LocalDailyAudioPractice.self,
            LocalKnownKanjiSnapshot.self,
        ])
        let configuration = ModelConfiguration(
            "ConvoLab",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
