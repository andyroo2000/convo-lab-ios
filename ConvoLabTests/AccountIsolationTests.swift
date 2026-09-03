import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class AccountIsolationTests: XCTestCase {
    nonisolated(unsafe) static var retainedObservableStores: [AnyObject] = []

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
        try seedAccountDeletionRecords(in: container)
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

        try assertOnlySecondAccountRemains(in: container)
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

    private func seedAccountDeletionRecords(in container: ModelContainer) throws {
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
            container.mainContext.insert(LocalStudyOverviewSnapshot(
                userID: userID,
                payload: Data()
            ))
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
    }

    private func assertOnlySecondAccountRemains(in container: ModelContainer) throws {
        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalCardRecord.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(PendingMutation.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(PendingMutation.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(LocalDailyAudioPractice.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalDailyAudioPractice.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(CachedMediaRecord.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(CachedMediaRecord.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(LocalSyncState.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalSyncState.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(LocalStudyOverviewSnapshot.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalStudyOverviewSnapshot.self, userID: 2, in: container), 1)
        XCTAssertEqual(try localRecordCount(LocalKnownKanjiSnapshot.self, userID: 1, in: container), 0)
        XCTAssertEqual(try localRecordCount(LocalKnownKanjiSnapshot.self, userID: 2, in: container), 1)
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

    func makeClient(
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

    func localRecordCount<T: PersistentModel>(
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
            case let record as LocalStudyOverviewSnapshot: record.userID == userID
            case let record as LocalKnownKanjiSnapshot: record.userID == userID
            default: false
            }
        }.count
    }
}
