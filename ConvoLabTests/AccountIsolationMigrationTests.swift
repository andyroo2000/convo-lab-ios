import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension AccountIsolationTests {
    func testPreAccountScopingStoreMigratesWithoutLosingTheOutbox() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "ConvoLabMigration-\(UUID().uuidString).store")
        let sidecarURLs = [
            storeURL,
            URL(filePath: storeURL.path + "-shm"),
            URL(filePath: storeURL.path + "-wal"),
        ]
        defer {
            for url in sidecarURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let cardPayload = Data("legacy-card-payload".utf8)
        let mutationPayload = Data("unsent-mutation".utf8)
        let practicePayload = Data("legacy-practice".utf8)

        try createLegacyStore(
            at: storeURL,
            cardPayload: cardPayload,
            mutationPayload: mutationPayload,
            practicePayload: practicePayload
        )

        let migrated = try Persistence.makeContainer(storeURL: storeURL)
        let context = migrated.mainContext
        let cards = try context.fetch(FetchDescriptor<LocalCardRecord>())
        let mutations = try context.fetch(FetchDescriptor<PendingMutation>())
        let media = try context.fetch(FetchDescriptor<CachedMediaRecord>())
        let practices = try context.fetch(FetchDescriptor<LocalDailyAudioPractice>())

        XCTAssertEqual(cards.first?.id, "legacy-card")
        XCTAssertEqual(cards.first?.syncID, "legacy-card")
        XCTAssertEqual(cards.first?.payload, cardPayload)
        XCTAssertEqual(cards.first?.userID, 0)
        XCTAssertEqual(mutations.first?.resourceID, "legacy-card")
        XCTAssertEqual(mutations.first?.payload, mutationPayload)
        XCTAssertEqual(mutations.first?.userID, 0)
        XCTAssertEqual(media.first?.remoteURL, "/legacy-audio.mp3")
        XCTAssertEqual(media.first?.userID, 0)
        XCTAssertEqual(practices.first?.payload, practicePayload)
        XCTAssertEqual(practices.first?.userID, 0)

        let suiteName = "AccountIsolationMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try Persistence.claimLegacyLocalData(
            for: 42,
            context: context,
            defaults: defaults
        )

        XCTAssertEqual(cards.first?.userID, 42)
        XCTAssertEqual(mutations.first?.userID, 42)
        XCTAssertEqual(media.first?.userID, 42)
        XCTAssertEqual(practices.first?.userID, 42)
    }

    func testAccountScopedStoreBackfillsIndexedSyncIdentityWithoutLosingState() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "ConvoLabV2Migration-\(UUID().uuidString).store")
        let sidecarURLs = [
            storeURL,
            URL(filePath: storeURL.path + "-shm"),
            URL(filePath: storeURL.path + "-wal"),
        ]
        defer {
            for url in sidecarURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let aliasedPayload = try JSONSerialization.data(withJSONObject: [
            "id": "local-card",
            "syncId": "SERVER-CARD",
        ])
        let otherUserPayload = try JSONSerialization.data(withJSONObject: [
            "id": "other-user-card",
            "syncId": "SERVER-CARD",
        ])
        let corruptPayload = Data("not-json".utf8)
        let serverUpdatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let locallyUpdatedAt = Date(timeIntervalSince1970: 1_750_000_100)
        let mediaPreparedAt = Date(timeIntervalSince1970: 1_750_000_200)

        try createAccountScopedStore(
            at: storeURL,
            aliasedPayload: aliasedPayload,
            otherUserPayload: otherUserPayload,
            corruptPayload: corruptPayload,
            serverUpdatedAt: serverUpdatedAt,
            locallyUpdatedAt: locallyUpdatedAt,
            mediaPreparedAt: mediaPreparedAt
        )

        let migrated = try Persistence.makeContainer(storeURL: storeURL)
        let context = migrated.mainContext
        let cards = try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                sortBy: [SortDescriptor(\.id)]
            )
        )
        let mutations = try context.fetch(FetchDescriptor<PendingMutation>())
        let syncStates = try context.fetch(FetchDescriptor<LocalSyncState>())

        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.first(where: { $0.id == "local-card" })?.normalizedID, "local-card")
        XCTAssertEqual(cards.first(where: { $0.id == "local-card" })?.syncID, "server-card")
        XCTAssertEqual(cards.first(where: { $0.id == "other-user-card" })?.syncID, "server-card")
        XCTAssertEqual(cards.first(where: { $0.id == "CORRUPT-CARD" })?.syncID, "corrupt-card")
        XCTAssertEqual(
            cards.first(where: { $0.id == "CORRUPT-CARD" })?.normalizedID,
            "corrupt-card"
        )

        let localCard = try XCTUnwrap(cards.first(where: { $0.id == "local-card" }))
        XCTAssertEqual(localCard.userID, 1)
        XCTAssertEqual(localCard.queueIndex, 7)
        XCTAssertFalse(localCard.isInActiveSession)
        XCTAssertEqual(localCard.mediaPreparedAt, mediaPreparedAt)
        XCTAssertEqual(localCard.serverUpdatedAt, serverUpdatedAt)
        XCTAssertEqual(localCard.locallyUpdatedAt, locallyUpdatedAt)

        XCTAssertEqual(cards.first(where: { $0.id == "other-user-card" })?.userID, 2)
        XCTAssertEqual(mutations.first?.userID, 1)
        XCTAssertEqual(mutations.first?.resourceID, "local-card")
        XCTAssertEqual(mutations.first?.attemptCount, 2)
        XCTAssertEqual(syncStates.first?.userID, 1)
        XCTAssertEqual(syncStates.first?.cardCheckpoint, 41)
    }

    private func createLegacyStore(
        at storeURL: URL,
        cardPayload: Data,
        mutationPayload: Data,
        practicePayload: Data
    ) throws {
        let schema = Schema(versionedSchema: ConvoLabSchemaV1.self)
        let configuration = ModelConfiguration(
            "ConvoLab",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = container.mainContext
        context.insert(ConvoLabSchemaV1.LocalCardRecord(
            id: "legacy-card",
            payload: cardPayload,
            queueIndex: 3,
            serverUpdatedAt: .now
        ))
        context.insert(ConvoLabSchemaV1.PendingMutation(
            id: "legacy-mutation",
            kind: "cardUpdate",
            resourceID: "legacy-card",
            payload: mutationPayload
        ))
        context.insert(ConvoLabSchemaV1.CachedMediaRecord(
            remoteURL: "/legacy-audio.mp3",
            relativePath: "legacy-audio.mp3",
            byteCount: 12,
            category: "offline-study"
        ))
        context.insert(ConvoLabSchemaV1.LocalDailyAudioPractice(
            id: "legacy-practice",
            payload: practicePayload,
            practiceDate: "2026-07-25",
            status: "ready",
            updatedAt: .now
        ))
        context.insert(ConvoLabSchemaV1.LocalKnownKanjiSnapshot(
            userID: 42,
            payload: Data("known-kanji".utf8)
        ))
        try context.save()
    }

    private func createAccountScopedStore(
        at storeURL: URL,
        aliasedPayload: Data,
        otherUserPayload: Data,
        corruptPayload: Data,
        serverUpdatedAt: Date,
        locallyUpdatedAt: Date,
        mediaPreparedAt: Date
    ) throws {
        let schema = Schema(versionedSchema: ConvoLabSchemaV2.self)
        let configuration = ModelConfiguration(
            "ConvoLab",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let context = container.mainContext
        context.insert(ConvoLabSchemaV2.LocalCardRecord(
            id: "local-card",
            userID: 1,
            payload: aliasedPayload,
            queueIndex: 7,
            isInActiveSession: false,
            mediaPreparedAt: mediaPreparedAt,
            serverUpdatedAt: serverUpdatedAt,
            locallyUpdatedAt: locallyUpdatedAt
        ))
        context.insert(ConvoLabSchemaV2.LocalCardRecord(
            id: "other-user-card",
            userID: 2,
            payload: otherUserPayload,
            queueIndex: 3,
            serverUpdatedAt: serverUpdatedAt
        ))
        context.insert(ConvoLabSchemaV2.LocalCardRecord(
            id: "CORRUPT-CARD",
            userID: 1,
            payload: corruptPayload,
            queueIndex: 5,
            serverUpdatedAt: serverUpdatedAt
        ))
        let mutation = ConvoLabSchemaV2.PendingMutation(
            id: "pending-mutation",
            kind: "cardUpdate",
            userID: 1,
            resourceID: "local-card",
            payload: aliasedPayload
        )
        mutation.attemptCount = 2
        context.insert(mutation)
        context.insert(ConvoLabSchemaV2.LocalSyncState(
            userID: 1,
            cardCheckpoint: 41
        ))
        try context.save()
    }
}
