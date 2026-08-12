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

@Model
final class LocalCardRecord {
    #Unique<LocalCardRecord>([\.userID, \.id])
    #Index<LocalCardRecord>(
        [\.userID, \.normalizedID],
        [\.userID, \.syncID]
    )
    var id: String
    var userID: Int = 0
    var normalizedID: String = ""
    var syncID: String = ""
    var payload: Data
    var queueIndex: Int
    var isInActiveSession: Bool
    var mediaPreparedAt: Date?
    var serverUpdatedAt: Date
    var locallyUpdatedAt: Date?

    init(card: StudyCard, userID: Int, queueIndex: Int, payload: Data) {
        id = card.id
        self.userID = userID
        normalizedID = card.id.lowercased()
        syncID = Self.canonicalSyncID(cardID: card.id, payload: payload)
        self.payload = payload
        self.queueIndex = queueIndex
        isInActiveSession = true
        serverUpdatedAt = card.updatedAt
    }

    func replacePayload(encoded payload: Data) {
        syncID = Self.canonicalSyncID(cardID: id, payload: payload)
        self.payload = payload
    }

    func replaceID(with id: String) {
        self.id = id
        normalizedID = id.lowercased()
    }

    nonisolated static func canonicalSyncID(cardID: String, payload: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let syncID = object["syncId"] as? String,
            !syncID.isEmpty
        else {
            return cardID.lowercased()
        }
        return syncID.lowercased()
    }
}

@Model
final class PendingMutation {
    @Attribute(.unique) var id: String
    var kind: String
    var userID: Int = 0
    var resourceID: String
    var payload: Data
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?

    init(kind: String, userID: Int, resourceID: String, payload: Data) {
        id = UUID().uuidString.lowercased()
        self.kind = kind
        self.userID = userID
        self.resourceID = resourceID
        self.payload = payload
        createdAt = .now
        attemptCount = 0
    }
}

@Model
final class CachedMediaRecord {
    #Unique<CachedMediaRecord>([\.userID, \.remoteURL])
    var remoteURL: String
    var userID: Int = 0
    var relativePath: String
    var byteCount: Int64
    var lastAccessedAt: Date
    var category: String

    init(
        remoteURL: String,
        userID: Int,
        relativePath: String,
        byteCount: Int64,
        category: String
    ) {
        self.remoteURL = remoteURL
        self.userID = userID
        self.relativePath = relativePath
        self.byteCount = byteCount
        lastAccessedAt = .now
        self.category = category
    }
}

@Model
final class LocalDailyAudioPractice {
    #Unique<LocalDailyAudioPractice>([\.userID, \.id])
    var id: String
    var userID: Int = 0
    var payload: Data
    var practiceDate: String
    var status: String
    var updatedAt: Date

    init(practice: DailyAudioPractice, userID: Int, payload: Data) {
        id = practice.id
        self.userID = userID
        self.payload = payload
        practiceDate = practice.practiceDate
        status = practice.status
        updatedAt = practice.updatedAt
    }
}

@Model
final class LocalSyncState {
    @Attribute(.unique) var userID: Int
    var cardCheckpoint: Int64
    var updatedAt: Date

    init(userID: Int, cardCheckpoint: Int64 = 0) {
        self.userID = userID
        self.cardCheckpoint = cardCheckpoint
        updatedAt = .now
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

enum ConvoLabSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let models: [any PersistentModel.Type] = [
        LocalCardRecord.self,
        PendingMutation.self,
        CachedMediaRecord.self,
        LocalDailyAudioPractice.self,
        LocalKnownKanjiSnapshot.self,
        LocalSyncState.self,
    ]

    @Model
    final class LocalCardRecord {
        #Unique<LocalCardRecord>([\.userID, \.id])
        var id: String
        var userID: Int = 0
        var payload: Data
        var queueIndex: Int
        var isInActiveSession: Bool
        var mediaPreparedAt: Date?
        var serverUpdatedAt: Date
        var locallyUpdatedAt: Date?

        init(
            id: String,
            userID: Int,
            payload: Data,
            queueIndex: Int,
            isInActiveSession: Bool = true,
            mediaPreparedAt: Date? = nil,
            serverUpdatedAt: Date,
            locallyUpdatedAt: Date? = nil
        ) {
            self.id = id
            self.userID = userID
            self.payload = payload
            self.queueIndex = queueIndex
            self.isInActiveSession = isInActiveSession
            self.mediaPreparedAt = mediaPreparedAt
            self.serverUpdatedAt = serverUpdatedAt
            self.locallyUpdatedAt = locallyUpdatedAt
        }
    }

    @Model
    final class PendingMutation {
        @Attribute(.unique) var id: String
        var kind: String
        var userID: Int = 0
        var resourceID: String
        var payload: Data
        var createdAt: Date
        var attemptCount: Int
        var lastAttemptAt: Date?
        var lastError: String?

        init(
            id: String,
            kind: String,
            userID: Int,
            resourceID: String,
            payload: Data
        ) {
            self.id = id
            self.kind = kind
            self.userID = userID
            self.resourceID = resourceID
            self.payload = payload
            createdAt = .now
            attemptCount = 0
        }
    }

    @Model
    final class CachedMediaRecord {
        #Unique<CachedMediaRecord>([\.userID, \.remoteURL])
        var remoteURL: String
        var userID: Int = 0
        var relativePath: String
        var byteCount: Int64
        var lastAccessedAt: Date
        var category: String

        init(
            remoteURL: String,
            userID: Int,
            relativePath: String,
            byteCount: Int64,
            category: String
        ) {
            self.remoteURL = remoteURL
            self.userID = userID
            self.relativePath = relativePath
            self.byteCount = byteCount
            lastAccessedAt = .now
            self.category = category
        }
    }

    @Model
    final class LocalDailyAudioPractice {
        #Unique<LocalDailyAudioPractice>([\.userID, \.id])
        var id: String
        var userID: Int = 0
        var payload: Data
        var practiceDate: String
        var status: String
        var updatedAt: Date

        init(
            id: String,
            userID: Int,
            payload: Data,
            practiceDate: String,
            status: String,
            updatedAt: Date
        ) {
            self.id = id
            self.userID = userID
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

    @Model
    final class LocalSyncState {
        @Attribute(.unique) var userID: Int
        var cardCheckpoint: Int64
        var updatedAt: Date

        init(userID: Int, cardCheckpoint: Int64 = 0) {
            self.userID = userID
            self.cardCheckpoint = cardCheckpoint
            updatedAt = .now
        }
    }
}

enum ConvoLabSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static let models: [any PersistentModel.Type] = [
        LocalCardRecord.self,
        PendingMutation.self,
        CachedMediaRecord.self,
        LocalDailyAudioPractice.self,
        LocalKnownKanjiSnapshot.self,
        LocalSyncState.self,
    ]
}

enum ConvoLabMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        ConvoLabSchemaV1.self,
        ConvoLabSchemaV2.self,
        ConvoLabSchemaV3.self,
    ]
    static let stages: [MigrationStage] = [
        .lightweight(
            fromVersion: ConvoLabSchemaV1.self,
            toVersion: ConvoLabSchemaV2.self
        ),
        .custom(
            fromVersion: ConvoLabSchemaV2.self,
            toVersion: ConvoLabSchemaV3.self,
            willMigrate: nil,
            didMigrate: { context in
                for record in try context.fetch(FetchDescriptor<LocalCardRecord>()) {
                    record.normalizedID = record.id.lowercased()
                    record.syncID = LocalCardRecord.canonicalSyncID(
                        cardID: record.id,
                        payload: record.payload
                    )
                }
                try context.save()
            }
        ),
    ]
}

enum Persistence {
    private static let legacyClaimCompletedKey =
        "ConvoLab.persistence.accountScopedLegacyClaimCompleted"

    static func claimLegacyLocalData(
        for userID: Int,
        context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws {
        guard !defaults.bool(forKey: legacyClaimCompletedKey) else { return }
        let legacyCards = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 0 }
            )
        )
        let legacyMutations = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.userID == 0 }
            )
        )
        let legacyMedia = try context.fetch(
            FetchDescriptor<CachedMediaRecord>(
                predicate: #Predicate { $0.userID == 0 }
            )
        )
        let legacyPractices = try context.fetch(
            FetchDescriptor<LocalDailyAudioPractice>(
                predicate: #Predicate { $0.userID == 0 }
            )
        )
        legacyCards.forEach { $0.userID = userID }
        legacyMutations.forEach { $0.userID = userID }
        legacyMedia.forEach { $0.userID = userID }
        legacyPractices.forEach { $0.userID = userID }
        if !legacyCards.isEmpty
            || !legacyMutations.isEmpty
            || !legacyMedia.isEmpty
            || !legacyPractices.isEmpty
        {
            try context.save()
        }
        // This marker lives outside SwiftData so a later account can never inherit
        // zero-scoped rows, even if cleanup or a partial store restore leaves one behind.
        defaults.set(true, forKey: legacyClaimCompletedKey)
    }

    static func makeContainer(
        inMemory: Bool = false,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: ConvoLabSchemaV3.self)
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(
                "ConvoLab",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "ConvoLab",
                schema: schema,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: ConvoLabMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
