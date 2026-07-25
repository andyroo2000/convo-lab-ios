import Foundation
import SwiftData

@Model
final class LocalCardRecord {
    var id: String
    var userID: Int = 0
    var payload: Data
    var queueIndex: Int
    var isInActiveSession: Bool
    var mediaPreparedAt: Date?
    var serverUpdatedAt: Date
    var locallyUpdatedAt: Date?

    init(card: StudyCard, userID: Int = 1, queueIndex: Int, payload: Data) {
        id = card.id
        self.userID = userID
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
    var userID: Int = 0
    var resourceID: String
    var payload: Data
    var createdAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?

    init(kind: String, userID: Int = 1, resourceID: String, payload: Data) {
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
    var remoteURL: String
    var userID: Int = 0
    var relativePath: String
    var byteCount: Int64
    var lastAccessedAt: Date
    var category: String

    init(
        remoteURL: String,
        userID: Int = 1,
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
    var id: String
    var userID: Int = 0
    var payload: Data
    var practiceDate: String
    var status: String
    var updatedAt: Date

    init(practice: DailyAudioPractice, userID: Int = 1, payload: Data) {
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

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            LocalCardRecord.self,
            PendingMutation.self,
            CachedMediaRecord.self,
            LocalDailyAudioPractice.self,
            LocalKnownKanjiSnapshot.self,
            LocalSyncState.self,
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
