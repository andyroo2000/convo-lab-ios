import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class StudyStoreSyncPublicationTests: XCTestCase {
    @MainActor
    func testSynchronizationPrunesTombstoneFromEveryPublishedCardCollection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deleted = makeCard(
            id: "local-deleted",
            syncId: "server-deleted",
            expression: "削除"
        )
        let survivor = makeCard(id: "survivor", expression: "保持")
        for (index, card) in [deleted, survivor].enumerated() {
            container.mainContext.insert(LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: index,
                payload: try StorageCodec.encoder.encode(card)
            ))
        }
        try container.mainContext.save()
        let allCardsData = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [deleted, survivor], limit: 50, nextCursor: nil)
        )
        let lessonData = try sessionResponseData(cards: [deleted, survivor])
        let deletedSyncID = try XCTUnwrap(deleted.syncId)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/study/cards":
                return Self.response(data: allCardsData)
            case "/api/study/lessons/start":
                return Self.response(data: lessonData)
            case "/api/sync/feed":
                return Self.response(data: Data(
                    """
                    {"data":[{"checkpoint":1,"resource_id":"\(deletedSyncID)","operation":"delete"}],
                    "meta":{"next_checkpoint":1,"has_more":false}}
                    """.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/offline-reserve":
                return Self.response(
                    statusCode: 500,
                    data: Data(#"{"message":"Unavailable"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        try await store.refreshAllCards()
        store.beginLessonSessionPresentation()
        defer { store.endLessonSessionPresentation() }
        try await store.refreshLessons()

        await store.synchronize()

        XCTAssertEqual(store.cards.map(\.id), [survivor.id])
        XCTAssertEqual(store.libraryCards.map(\.id), [survivor.id])
        XCTAssertEqual(store.allCards.map(\.id), [survivor.id])
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).map(\.id),
            [survivor.id]
        )
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            1
        )
        XCTAssertFalse(paths.values.contains("/api/study/session/start"))
        guard case .failed = store.syncStatus else {
            return XCTFail("The later reserve failure should not undo tombstone pruning.")
        }
    }

    @MainActor
    func testSynchronizationPublishesOnlyCommittedPageTombstonesWhenLaterPageFails() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deleted = makeCard(
            id: "committed-delete",
            syncId: "committed-delete-sync",
            expression: "削除"
        )
        let retained = makeCard(
            id: "failed-delete",
            syncId: "failed-delete-sync",
            expression: "保持"
        )
        for (index, card) in [deleted, retained].enumerated() {
            container.mainContext.insert(LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: index,
                payload: try StorageCodec.encoder.encode(card)
            ))
        }
        try container.mainContext.save()
        let allCardsData = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [deleted, retained], limit: 50, nextCursor: nil)
        )
        let deletedSyncID = try XCTUnwrap(deleted.syncId)
        let retainedSyncID = try XCTUnwrap(retained.syncId)
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                return Self.response(data: allCardsData)
            case "/api/sync/feed":
                if feedRequests.next() == 1 {
                    return Self.response(data: Data(
                        """
                        {"data":[{"checkpoint":1,"resource_id":"\(deletedSyncID)","operation":"delete"}],
                        "meta":{"next_checkpoint":1,"has_more":true}}
                        """.utf8
                    ))
                }
                return Self.response(data: Data(
                    """
                    {"data":[{"checkpoint":2,"resource_id":"\(retainedSyncID)","operation":"delete"}],
                    "meta":{"next_checkpoint":1,"has_more":false}}
                    """.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/offline-reserve":
                return Self.response(
                    statusCode: 500,
                    data: Data(#"{"message":"Unavailable"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        try await store.refreshAllCards()
        store.beginLessonSessionPresentation()
        defer { store.endLessonSessionPresentation() }

        await store.synchronize()

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [retained.id])
        XCTAssertEqual(store.allCards.map(\.id), [retained.id])
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).map(\.id),
            [retained.id]
        )
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            1
        )
        guard case .failed = store.syncStatus else {
            return XCTFail("The rejected second page should fail synchronization.")
        }
    }

    @MainActor
    func testSynchronizationRestoresPublishedCardWhenLaterPageCancelsTombstone() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let originalCard = makeCard(
            id: "restored-card",
            syncId: "restored-card-sync",
            expression: "同期前"
        )
        let restoredCard = makeCard(
            id: originalCard.id,
            syncId: originalCard.syncId,
            expression: "同期後"
        )
        container.mainContext.insert(LocalCardRecord(
            card: originalCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(originalCard)
        ))
        try container.mainContext.save()
        let allCardsData = try StorageCodec.encoder.encode(
            StudyCardListResponse(items: [originalCard], limit: 50, nextCursor: nil)
        )
        let cardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(restoredCard)
        )
        let batchData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let syncID = try XCTUnwrap(originalCard.syncId)
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/cards":
                return Self.response(data: allCardsData)
            case "/api/sync/feed":
                if feedRequests.next() == 1 {
                    return Self.response(data: Data(
                        """
                        {"data":[{"checkpoint":1,"resource_id":"\(syncID)","operation":"delete"}],
                        "meta":{"next_checkpoint":1,"has_more":true}}
                        """.utf8
                    ))
                }
                return Self.response(data: Data(
                    """
                    {"data":[{"checkpoint":2,"resource_id":"\(syncID)","operation":"update"}],
                    "meta":{"next_checkpoint":2,"has_more":false}}
                    """.utf8
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/offline-reserve":
                return Self.response(
                    statusCode: 500,
                    data: Data(#"{"message":"Unavailable"}"#.utf8)
                )
            default:
                throw URLError(.badURL)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        try await store.refreshAllCards()
        store.beginLessonSessionPresentation()
        defer { store.endLessonSessionPresentation() }

        await store.synchronize()

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.promptText), [restoredCard.promptText])
        XCTAssertEqual(store.allCards.map(\.promptText), [restoredCard.promptText])
        let persistedRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertEqual(
            try StorageCodec.decoder.decode(
                StudyCard.self,
                from: persistedRecord.payload
            ).promptText,
            restoredCard.promptText
        )
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            2
        )
        guard case .failed = store.syncStatus else {
            return XCTFail("The later reserve failure should not hide the restored card.")
        }
    }

    @MainActor
    func testCheckpointResetClearsOtherPreparedMarkersDuringPresentedLesson() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dirty = makeCard(
            id: "dirty",
            expression: "編集中",
            dueAt: .distantFuture
        )
        let dirtyRecord = LocalCardRecord(
            card: dirty,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(dirty)
        )
        dirtyRecord.isInActiveSession = false
        dirtyRecord.locallyUpdatedAt = .now
        dirtyRecord.mediaPreparedAt = .now
        let clean = makeCard(id: "clean", expression: "再取得対象")
        let cleanRecord = LocalCardRecord(
            card: clean,
            userID: 1,
            queueIndex: 1,
            payload: try StorageCodec.encoder.encode(clean)
        )
        let activeReview = makeCard(
            id: "active-review",
            expression: "保持する復習",
            dueAt: .distantFuture
        )
        let activeReviewRecord = LocalCardRecord(
            card: activeReview,
            userID: 1,
            queueIndex: 17,
            payload: try StorageCodec.encoder.encode(activeReview)
        )
        activeReviewRecord.locallyUpdatedAt = .now
        activeReviewRecord.mediaPreparedAt = .now
        container.mainContext.insert(dirtyRecord)
        container.mainContext.insert(cleanRecord)
        container.mainContext.insert(activeReviewRecord)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 99))
        try container.mainContext.save()
        let allCardsData = try StorageCodec.encoder.encode(
            StudyCardListResponse(
                items: [clean, dirty, activeReview],
                limit: 50,
                nextCursor: nil
            )
        )
        let activeReviewObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(activeReview)
        )
        let reserveData = try JSONSerialization.data(withJSONObject: [
            "cards": [activeReviewObject],
            "reserveDays": 5,
            "generatedAt": "2026-07-25T12:00:00.000Z",
            "horizonEndsAt": "2026-07-30T12:00:00.000Z",
        ])
        let presentedLesson = makeCard(
            id: "presented-during-checkpoint-reset",
            expression: "表示中のレッスン",
            queueState: "new"
        )
        let lessonData = try sessionResponseData(cards: [presentedLesson])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/study/cards":
                return Self.response(data: allCardsData)
            case "/api/study/lessons/start":
                return Self.response(data: lessonData)
            case "/api/sync/feed":
                return Self.response(
                    statusCode: 409,
                    data: Data(#"{"message":"Checkpoint expired"}"#.utf8)
                )
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/offline-reserve":
                return Self.response(data: reserveData)
            default:
                throw URLError(.badURL)
            }
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
        try await store.refreshAllCards()
        store.beginLessonSessionPresentation()
        defer { store.endLessonSessionPresentation() }
        try await store.refreshLessons()

        await store.synchronize()

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards",
                "/api/study/lessons/start",
                "/api/sync/feed",
                "/api/study/known-kanji",
                "/api/study/offline-reserve",
            ]
        )
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            0
        )
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        let preservedDirtyRecord = try XCTUnwrap(records.first { $0.id == dirty.id })
        let preservedActiveReviewRecord = try XCTUnwrap(
            records.first { $0.id == activeReview.id }
        )
        XCTAssertNotNil(preservedDirtyRecord.locallyUpdatedAt)
        XCTAssertNil(preservedDirtyRecord.mediaPreparedAt)
        XCTAssertEqual(preservedActiveReviewRecord.queueIndex, 17)
        XCTAssertNotNil(preservedActiveReviewRecord.mediaPreparedAt)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertNil(records.first { $0.id == presentedLesson.id })
        XCTAssertEqual(Set(store.allCards.map(\.id)), Set([dirty.id, activeReview.id]))
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    private func makeClient(
        handler: @escaping SyncPublicationURLProtocol.Handler
    ) -> APIClient {
        let host = "sync-publication-\(UUID().uuidString.lowercased()).example"
        SyncPublicationURLProtocol.install(handler, forHost: host)
        addTeardownBlock {
            SyncPublicationURLProtocol.removeHandler(forHost: host)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncPublicationURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeCard(
        id: String,
        syncId: String? = nil,
        expression: String,
        queueState: String = "review",
        dueAt: Date? = nil
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncId,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(expression)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: dueAt,
                introducedAt: nil,
                failedAt: nil,
                queueState: queueState,
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            masteryLevel: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    @MainActor
    private func sessionResponseData(
        cards: [StudyCard],
        lessonBatchSize: Int = 5
    ) throws -> Data {
        let session = StudySession(
            overview: StudyOverview(
                dueCount: cards.filter { $0.state.queueState != "new" }.count,
                newCount: cards.filter { $0.state.queueState == "new" }.count,
                reviewCount: cards.filter { $0.state.queueState != "new" }.count,
                newCardsPerDay: 20,
                newCardsAvailableToday: cards.filter { $0.state.queueState == "new" }.count,
                lessonBatchSize: lessonBatchSize
            ),
            cards: cards
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        return try JSONSerialization.data(withJSONObject: ["data": object])
    }

    private static func response(
        statusCode: Int = 200,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}

private final class SyncPublicationURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlersByHost: [String: Handler] = [:]

    static func install(_ handler: @escaping Handler, forHost host: String) {
        lock.lock()
        handlersByHost[host] = handler
        lock.unlock()
    }

    static func removeHandler(forHost host: String) {
        lock.lock()
        handlersByHost.removeValue(forKey: host)
        lock.unlock()
    }

    private static func handler(forHost host: String?) -> Handler? {
        guard let host else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return handlersByHost[host]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(forHost: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
