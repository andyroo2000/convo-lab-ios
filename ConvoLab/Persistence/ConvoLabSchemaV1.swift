import Foundation
import SwiftData

// This is the exact on-disk schema shipped before local records were scoped by
// account. Keep it immutable: SwiftData uses it to migrate existing installs.
enum ConvoLabSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        LocalCardRecord.self,
        PendingMutation.self,
        CachedMediaRecord.self,
        LocalDailyAudioPractice.self,
        LocalKnownKanjiSnapshot.self,
    ]

    @Model
    final class LocalCardRecord {
        @Attribute(.unique) var id: String
        var payload: Data
        var queueIndex: Int
        var isInActiveSession: Bool
        var mediaPreparedAt: Date?
        var serverUpdatedAt: Date
        var locallyUpdatedAt: Date?

        init(
            id: String,
            payload: Data,
            queueIndex: Int,
            serverUpdatedAt: Date
        ) {
            self.id = id
            self.payload = payload
            self.queueIndex = queueIndex
            isInActiveSession = true
            self.serverUpdatedAt = serverUpdatedAt
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

        init(id: String, kind: String, resourceID: String, payload: Data) {
            self.id = id
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

        init(
            remoteURL: String,
            relativePath: String,
            byteCount: Int64,
            category: String
        ) {
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

        init(
            id: String,
            payload: Data,
            practiceDate: String,
            status: String,
            updatedAt: Date
        ) {
            self.id = id
            self.payload = payload
            self.practiceDate = practiceDate
            self.status = status
            self.updatedAt = updatedAt
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
}
