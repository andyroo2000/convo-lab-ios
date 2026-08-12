import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AccountIsolationTests: XCTestCase {
    private nonisolated(unsafe) static var retainedObservableStores: [AnyObject] = []

    func testStudyStoreOnlyLoadsTheActiveUsersCards() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        try insertCard(id: "user-one-card", userID: 1, into: container)
        try insertCard(id: "user-two-card", userID: 2, into: container)
        let client = makeClient()
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activate(userID: 1)
        XCTAssertEqual(store.cards.map(\.id), ["user-one-card"])

        store.activate(userID: 2)
        XCTAssertEqual(store.cards.map(\.id), ["user-two-card"])

        store.deactivate()
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        // Observation's iOS 26 simulator runtime can double-free task-local
        // teardown state when a switched @Observable is released inside XCTest.
        Self.retainedObservableStores.append(store)
    }

    func testDailyAudioStoreOnlyLoadsTheActiveUsersPractices() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        try insertPractice(id: "practice-one", userID: 1, into: container)
        try insertPractice(id: "practice-two", userID: 2, into: container)
        let client = makeClient()
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = DailyAudioStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        store.activate(userID: 1)
        XCTAssertEqual(store.practices.map(\.id), ["practice-one"])

        store.activate(userID: 2)
        XCTAssertEqual(store.practices.map(\.id), ["practice-two"])

        store.deactivate()
        XCTAssertTrue(store.practices.isEmpty)
        Self.retainedObservableStores.append(store)
    }

    func testMediaCacheSeparatesAndClearsDownloadsByUser() async throws {
        let requestCounter = AccountIsolationCounter()
        let client = makeClient { request in
            let version = requestCounter.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("audio-\(version)".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/shared")!

        cache.activate(userID: 1)
        let userOneURL = try await cache.download(remoteURL, category: "active-study")

        cache.activate(userID: 2)
        XCTAssertNil(cache.localURL(for: remoteURL))
        let userTwoURL = try await cache.download(remoteURL, category: "active-study")

        XCTAssertNotEqual(userOneURL, userTwoURL)
        XCTAssertEqual(requestCounter.current, 2)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            2
        )

        try cache.clearDownloadedMedia()
        XCTAssertNil(cache.localURL(for: remoteURL))

        cache.activate(userID: 1)
        XCTAssertEqual(cache.localURL(for: remoteURL), userOneURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userOneURL.path))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            1
        )
    }

    func testDeletingAnAccountPurgesOnlyThatUsersLocalData() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        try insertCard(id: "user-one-card", userID: 1, into: container)
        try insertCard(id: "user-two-card", userID: 2, into: container)
        try insertPractice(id: "practice-one", userID: 1, into: container)
        try insertPractice(id: "practice-two", userID: 2, into: container)
        for userID in [1, 2] {
            container.mainContext.insert(PendingMutation(
                kind: "cardUpdate",
                userID: userID,
                resourceID: "card-\(userID)",
                payload: Data()
            ))
            container.mainContext.insert(LocalSyncState(userID: userID, cardCheckpoint: 7))
            container.mainContext.insert(LocalKnownKanjiSnapshot(
                userID: userID,
                payload: Data()
            ))
            container.mainContext.insert(CachedMediaRecord(
                remoteURL: "media-\(userID)",
                userID: userID,
                relativePath: "missing-\(userID).mp3",
                byteCount: 1,
                category: "active-study"
            ))
        }
        try container.mainContext.save()
        let client = makeClient()
        let cache = MediaCache(api: client, context: container.mainContext)
        let study = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: cache
        )
        let dailyAudio = DailyAudioStore(
            api: client,
            context: container.mainContext,
            mediaCache: cache
        )

        try cache.deleteLocalData(userID: 1)
        try dailyAudio.deleteLocalData(userID: 1)
        try study.deleteLocalData(userID: 1)

        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(PendingMutation.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(PendingMutation.self, userID: 2, in: container), 1)
        XCTAssertEqual(
            try localRecordCount(LocalDailyAudioPractice.self, userID: 1, in: container),
            0
        )
        XCTAssertEqual(
            try localRecordCount(LocalDailyAudioPractice.self, userID: 2, in: container),
            1
        )
        XCTAssertEqual(try localRecordCount(CachedMediaRecord.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(CachedMediaRecord.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(LocalSyncState.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalSyncState.self, userID: 2, in: container), 1)
        XCTAssertEqual(
            try localRecordCount(LocalKnownKanjiSnapshot.self, userID: 1, in: container),
            0
        )
        XCTAssertEqual(
            try localRecordCount(LocalKnownKanjiSnapshot.self, userID: 2, in: container),
            1
        )
        Self.retainedObservableStores.append(study)
        Self.retainedObservableStores.append(dailyAudio)
    }

    func testLegacyUnscopedRowsAreClaimedByTheRestoredAccount() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let suiteName = "AccountIsolationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try insertCard(id: "legacy-card", userID: 0, into: container)
        try insertPractice(id: "legacy-practice", userID: 0, into: container)
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 0,
            resourceID: "legacy-card",
            payload: Data()
        ))
        container.mainContext.insert(CachedMediaRecord(
            remoteURL: "legacy-media",
            userID: 0,
            relativePath: "legacy.mp3",
            byteCount: 1,
            category: "active-study"
        ))
        try container.mainContext.save()

        try Persistence.claimLegacyLocalData(
            for: 42,
            context: container.mainContext,
            defaults: defaults
        )

        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 42, in: container), 1)
        XCTAssertEqual(try localRecordCount(PendingMutation.self, userID: 42, in: container), 1)
        XCTAssertEqual(try localRecordCount(CachedMediaRecord.self, userID: 42, in: container), 1)
        XCTAssertEqual(
            try localRecordCount(LocalDailyAudioPractice.self, userID: 42, in: container),
            1
        )
        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 0, in: container), 0)
        XCTAssertEqual(try localRecordCount(PendingMutation.self, userID: 0, in: container), 0)

        try insertCard(id: "unowned-late-row", userID: 0, into: container)
        try Persistence.claimLegacyLocalData(
            for: 84,
            context: container.mainContext,
            defaults: defaults
        )
        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 84, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 0, in: container), 1)
    }

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

    func testReplacingCardPayloadKeepsIndexedSyncIdentityInStep() throws {
        let originalPayload = try JSONSerialization.data(withJSONObject: [
            "syncId": "SERVER-ONE",
        ])
        let card = StudyCard(
            id: "LOCAL-CARD",
            syncId: "SERVER-ONE",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("prompt")]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: originalPayload
        )

        XCTAssertEqual(record.syncID, "server-one")
        XCTAssertEqual(record.normalizedID, "local-card")
        let replacement = try JSONSerialization.data(withJSONObject: [
            "syncId": "SERVER-TWO",
        ])
        record.replacePayload(encoded: replacement)
        XCTAssertEqual(record.payload, replacement)
        XCTAssertEqual(record.syncID, "server-two")

        let corruptReplacement = Data("not-json".utf8)
        record.replacePayload(encoded: corruptReplacement)
        XCTAssertEqual(record.payload, corruptReplacement)
        XCTAssertEqual(record.syncID, "local-card")
    }

    func testDailyAudioDownloadStopsWhenTheAccountChanges() async throws {
        let gate = AccountIsolationGate()
        let requestCounter = AccountIsolationCounter()
        let client = makeClient { request in
            _ = requestCounter.next()
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("old account audio".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let practiceID = "39ac4e14-b8b0-482c-8831-a3c1cb1987e9"
        let tracks = [0, 1].map { index in
            DailyAudioTrack(
                id: "4aa076b2-1bc7-45a8-b7b4-12b74dcbd46\(index)",
                practiceId: practiceID,
                mode: "drill",
                status: "ready",
                title: "Track \(index)",
                sortOrder: index,
                audioUrl: "/api/daily-audio-practice/\(practiceID)/tracks/\(index)/audio",
                approxDurationSeconds: 60,
                updatedAt: .now
            )
        }
        let practice = DailyAudioPractice(
            id: practiceID,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: tracks
        )
        container.mainContext.insert(LocalDailyAudioPractice(
            practice: practice,
            userID: 1,
            payload: try StorageCodec.encoder.encode(practice)
        ))
        try container.mainContext.save()
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = DailyAudioStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: cache
        )

        let download = Task { await store.download(practice) }
        for _ in 0..<100 where !gate.hasStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)
        store.activate(userID: 2)
        gate.release()
        await download.value

        XCTAssertTrue((1...tracks.count).contains(requestCounter.current))
        XCTAssertEqual(
            try localRecordCount(CachedMediaRecord.self, userID: 2, in: container),
            0
        )
        XCTAssertTrue(store.downloadingTrackIDs.isEmpty)
        XCTAssertNil(store.practiceDownloadProgress[practice.id])
        Self.retainedObservableStores.append(store)
    }

    func testDeletingMediaWhileDownloadIsInFlightCannotResurrectIt() async throws {
        let gate = AccountIsolationGate()
        let client = makeClient { request in
            gate.markStarted()
            gate.waitForRelease()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"]
                )!,
                Data("late audio".utf8)
            )
        }
        let container = try Persistence.makeContainer(inMemory: true)
        let cache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let remoteURL = URL(string: "/api/study/media/late")!
        let download = Task {
            try await cache.download(remoteURL, category: "offline-study")
        }
        for _ in 0..<100 where !gate.hasStarted {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasStarted)

        try cache.deleteLocalData(userID: 1)
        gate.release()
        _ = try? await download.value

        XCTAssertNil(cache.localURL(for: remoteURL))
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<CachedMediaRecord>()),
            0
        )
    }

    private func insertCard(
        id: String,
        userID: Int,
        into container: ModelContainer
    ) throws {
        let card = StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: .now,
                introducedAt: nil,
                failedAt: nil,
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let payload = try StorageCodec.encoder.encode(card)
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: userID,
                queueIndex: 0,
                payload: payload
            )
        )
        try container.mainContext.save()
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

    private func insertPractice(
        id: String,
        userID: Int,
        into container: ModelContainer
    ) throws {
        let practice = DailyAudioPractice(
            id: id,
            practiceDate: "2026-07-25",
            status: "ready",
            targetDurationMinutes: 30,
            errorMessage: nil,
            createdAt: .now,
            updatedAt: .now,
            tracks: []
        )
        container.mainContext.insert(
            LocalDailyAudioPractice(
                practice: practice,
                userID: userID,
                payload: try StorageCodec.encoder.encode(practice)
            )
        )
        try container.mainContext.save()
    }

    private func makeClient(
        handler: @escaping MockURLProtocol.Handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data("{}".utf8)
            )
        }
    ) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func localRecordCount<T: PersistentModel>(
        _ type: T.Type,
        userID: Int,
        in container: ModelContainer
    ) throws -> Int where T: AnyObject {
        let records = try container.mainContext.fetch(FetchDescriptor<T>())
        return records.filter {
            switch $0 {
            case let record as LocalCardRecord: record.userID == userID
            case let record as PendingMutation: record.userID == userID
            case let record as CachedMediaRecord: record.userID == userID
            case let record as LocalDailyAudioPractice: record.userID == userID
            case let record as LocalSyncState: record.userID == userID
            case let record as LocalKnownKanjiSnapshot: record.userID == userID
            default: false
            }
        }.count
    }
}

private final class AccountIsolationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.withLock { value }
    }

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class AccountIsolationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.withLock { started }
    }

    func markStarted() {
        condition.withLock {
            started = true
            condition.broadcast()
        }
    }

    func waitForRelease() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}
