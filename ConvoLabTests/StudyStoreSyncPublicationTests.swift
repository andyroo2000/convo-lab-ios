import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class StudyStoreSyncPublicationTests: XCTestCase {
    private struct CheckpointResetFixture {
        let dirty: StudyCard
        let activeReview: StudyCard
        let presentedLesson: StudyCard
        let cardListData: Data
        let reserveData: Data
        let lessonData: Data
    }

    @MainActor
    func testSynchronizationPrunesTombstoneFromEveryPublishedCardCollection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let deleted = makeCard(
            id: "local-deleted",
            syncId: "server-deleted",
            expression: "削除"
        )
        let survivor = makeCard(id: "survivor", expression: "保持")
        try insertCards([deleted, survivor], into: container)
        let lessonData = try sessionResponseData(cards: [deleted, survivor])
        let deletedSyncID = try XCTUnwrap(deleted.syncId)
        let script = SyncPublicationResponseScript(responses: [
            "/api/study/cards": [.success(data: try cardListData([deleted, survivor]))],
            "/api/study/lessons/start": [.success(data: lessonData)],
            "/api/sync/feed": [.success(data: Self.feedPage(
                syncID: deletedSyncID,
                operation: "delete",
                checkpoint: 1,
                hasMore: false
            ))],
            "/api/study/known-kanji": [.success(data: Self.knownKanjiData)],
            "/api/study/offline-reserve": [.failure],
        ])
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let client = makeClient(script: script)
        let store = makeStore(container: container, client: client, diagnosticsSink: diagnosticsSink)
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
        XCTAssertFalse(script.requestedPaths.contains("/api/study/session/start"))
        guard case .failed = store.syncStatus else {
            return XCTFail("The later reserve failure should not undo tombstone pruning.")
        }
        XCTAssertEqual(
            diagnosticsSink.events.filter { $0.operation == .synchronization },
            [
                .init(
                    operation: .synchronization,
                    stage: .began,
                    outcome: nil,
                    reason: nil,
                    itemCount: nil
                ),
                .init(
                    operation: .synchronization,
                    stage: .ended,
                    outcome: .failed,
                    reason: nil,
                    itemCount: nil
                ),
            ]
        )
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
        try insertCards([deleted, retained], into: container)
        let deletedSyncID = try XCTUnwrap(deleted.syncId)
        let retainedSyncID = try XCTUnwrap(retained.syncId)
        let script = SyncPublicationResponseScript(responses: [
            "/api/study/cards": [.success(data: try cardListData([deleted, retained]))],
            "/api/sync/feed": [
                .success(data: Self.feedPage(
                    syncID: deletedSyncID,
                    operation: "delete",
                    checkpoint: 1,
                    hasMore: true
                )),
                .success(data: Self.feedPage(
                    syncID: retainedSyncID,
                    operation: "delete",
                    checkpoint: 2,
                    nextCheckpoint: 1,
                    hasMore: false
                )),
            ],
            "/api/study/known-kanji": [.success(data: Self.knownKanjiData)],
            "/api/study/offline-reserve": [.failure],
        ])
        let client = makeClient(script: script)
        let store = makeStore(container: container, client: client)
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
        try insertCards([originalCard], into: container)
        let cardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(restoredCard)
        )
        let batchData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let syncID = try XCTUnwrap(originalCard.syncId)
        let script = SyncPublicationResponseScript(responses: [
            "/api/study/cards": [.success(data: try cardListData([originalCard]))],
            "/api/sync/feed": [
                .success(data: Self.feedPage(
                    syncID: syncID,
                    operation: "delete",
                    checkpoint: 1,
                    hasMore: true
                )),
                .success(data: Self.feedPage(
                    syncID: syncID,
                    operation: "update",
                    checkpoint: 2,
                    hasMore: false
                )),
            ],
            "/api/study/cards/batch": [.success(data: batchData)],
            "/api/study/known-kanji": [.success(data: Self.knownKanjiData)],
            "/api/study/offline-reserve": [.failure],
        ])
        let client = makeClient(script: script)
        let store = makeStore(container: container, client: client)
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
        let fixture = try makeCheckpointResetFixture(in: container)
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let script = SyncPublicationResponseScript(responses: [
            "/api/study/cards": [.success(data: fixture.cardListData)],
            "/api/study/lessons/start": [.success(data: fixture.lessonData)],
            "/api/sync/feed": [.checkpointExpired],
            "/api/study/known-kanji": [.success(data: Self.knownKanjiData)],
            "/api/study/offline-reserve": [.success(data: fixture.reserveData)],
        ])
        let client = makeClient(script: script)
        let store = makeStore(container: container, client: client, diagnosticsSink: diagnosticsSink)
        try await store.refreshAllCards()
        store.beginLessonSessionPresentation()
        defer { store.endLessonSessionPresentation() }
        try await store.refreshLessons()

        await store.synchronize()

        try assertCheckpointResetResult(
            store: store,
            container: container,
            fixture: fixture,
            diagnosticsSink: diagnosticsSink,
            requestedPaths: script.requestedPaths
        )
    }

    @MainActor
    private func makeCheckpointResetFixture(
        in container: ModelContainer
    ) throws -> CheckpointResetFixture {
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
        return CheckpointResetFixture(
            dirty: dirty,
            activeReview: activeReview,
            presentedLesson: presentedLesson,
            cardListData: try cardListData([clean, dirty, activeReview]),
            reserveData: reserveData,
            lessonData: lessonData
        )
    }

    @MainActor
    private func assertCheckpointResetResult(
        store: StudyStore,
        container: ModelContainer,
        fixture: CheckpointResetFixture,
        diagnosticsSink: RecordingNativeDiagnosticsSink,
        requestedPaths: [String]
    ) throws {
        XCTAssertEqual(
            requestedPaths,
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
        let preservedDirtyRecord = try XCTUnwrap(records.first { $0.id == fixture.dirty.id })
        let preservedActiveReviewRecord = try XCTUnwrap(
            records.first { $0.id == fixture.activeReview.id }
        )
        XCTAssertNotNil(preservedDirtyRecord.locallyUpdatedAt)
        XCTAssertNil(preservedDirtyRecord.mediaPreparedAt)
        XCTAssertEqual(preservedActiveReviewRecord.queueIndex, 17)
        XCTAssertNotNil(preservedActiveReviewRecord.mediaPreparedAt)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertNil(records.first { $0.id == fixture.presentedLesson.id })
        XCTAssertEqual(
            Set(store.allCards.map(\.id)),
            Set([fixture.dirty.id, fixture.activeReview.id])
        )
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(
            diagnosticsSink.events.filter { $0.operation == .synchronization }.last?.outcome,
            .succeeded
        )
    }

    @MainActor
    func testDeactivationEndsInFlightSynchronizationDiagnosticsAsCancelled() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let gate = BlockingSyncRequestGate()
        let diagnosticsSink = RecordingNativeDiagnosticsSink()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                gate.block()
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
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
            ),
            diagnostics: NativeDiagnostics(sink: diagnosticsSink)
        )

        let synchronization = Task { await store.synchronize() }
        let deadline = Date.now.addingTimeInterval(5)
        while !gate.isBlocked, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.isBlocked)
        store.deactivate()
        gate.release()
        await synchronization.value

        XCTAssertEqual(
            diagnosticsSink.events.filter { $0.operation == .synchronization },
            [
                .init(
                    operation: .synchronization,
                    stage: .began,
                    outcome: nil,
                    reason: nil,
                    itemCount: nil
                ),
                .init(
                    operation: .synchronization,
                    stage: .ended,
                    outcome: .cancelled,
                    reason: nil,
                    itemCount: nil
                ),
            ]
        )
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
    private func makeClient(script: SyncPublicationResponseScript) -> APIClient {
        makeClient { request in
            try script.response(for: request)
        }
    }

    @MainActor
    private func makeStore(
        container: ModelContainer,
        client: APIClient,
        diagnosticsSink: RecordingNativeDiagnosticsSink? = nil
    ) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            diagnostics: diagnosticsSink.map(NativeDiagnostics.init(sink:)) ?? .init()
        )
    }

    @MainActor
    private func insertCards(
        _ cards: [StudyCard],
        into container: ModelContainer
    ) throws {
        for (index, card) in cards.enumerated() {
            container.mainContext.insert(LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: index,
                payload: try StorageCodec.encoder.encode(card)
            ))
        }
        try container.mainContext.save()
    }

    @MainActor
    private func cardListData(_ cards: [StudyCard]) throws -> Data {
        try StorageCodec.encoder.encode(
            StudyCardListResponse(items: cards, limit: 50, nextCursor: nil)
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

    fileprivate static func response(
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

    private static let knownKanjiData = Data(
        #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
    )

    private static func feedPage(
        syncID: String,
        operation: String,
        checkpoint: Int,
        nextCheckpoint: Int? = nil,
        hasMore: Bool
    ) -> Data {
        let nextCheckpoint = nextCheckpoint ?? checkpoint
        return Data(
            """
            {"data":[{"checkpoint":\(checkpoint),"resource_id":"\(syncID)","operation":"\(operation)"}],
            "meta":{"next_checkpoint":\(nextCheckpoint),"has_more":\(hasMore)}}
            """.utf8
        )
    }
}

private struct SyncPublicationResponse: @unchecked Sendable {
    let statusCode: Int
    let data: Data

    static func success(data: Data) -> Self {
        .init(statusCode: 200, data: data)
    }

    static let failure = Self(
        statusCode: 500,
        data: Data(#"{"message":"Unavailable"}"#.utf8)
    )

    static let checkpointExpired = Self(
        statusCode: 409,
        data: Data(#"{"message":"Checkpoint expired"}"#.utf8)
    )
}

private final class SyncPublicationResponseScript: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [SyncPublicationResponse]]
    private var paths: [String] = []

    init(responses: [String: [SyncPublicationResponse]]) {
        self.responses = responses
    }

    var requestedPaths: [String] {
        lock.withLock { paths }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let scriptedResponse = try lock.withLock {
            paths.append(path)
            guard var queuedResponses = responses[path], !queuedResponses.isEmpty else {
                throw URLError(.badURL)
            }
            let response = queuedResponses.removeFirst()
            responses[path] = queuedResponses
            return response
        }
        return StudyStoreSyncPublicationTests.response(
            statusCode: scriptedResponse.statusCode,
            data: scriptedResponse.data
        )
    }
}

private final class BlockingSyncRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var blocked = false

    var isBlocked: Bool {
        lock.withLock { blocked }
    }

    func block() {
        lock.withLock { blocked = true }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func release() {
        semaphore.signal()
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
