import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRejectedReviewDoesNotBlockNewerReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let rejectedCard = makeCard(id: "01J00000000000000000000001", expression: "犬")
        let acceptedCard = makeCard(id: "01J00000000000000000000002", expression: "猫")
        let requestCounter = LockedCounter()
        let client = makeClient { request in
            let status = requestCounter.next() <= 2 ? 422 : 204
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                status == 422 ? Data(#"{"message":"Invalid review"}"#.utf8) : Data()
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        await store.recordReview(card: rejectedCard, rating: .good, duration: nil)
        await store.recordReview(card: acceptedCard, rating: .good, duration: nil)

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
            .filter { $0.kind == "review" }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.resourceID, rejectedCard.id)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        XCTAssertNotNil(pending.first?.lastError)
    }

    @MainActor
    func testOfflineReviewBacklogUploadsInOneBatch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
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
        let cards = (0..<4).map {
            makeCard(
                id: "01J000000000000000000000\(String(format: "%02d", $0))",
                expression: "card-\($0)"
            )
        }

        for card in cards.prefix(3) {
            await store.recordReview(card: card, rating: .good, duration: nil)
        }

        let uploadedBatchSizes = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
            uploadedBatchSizes.append(String(events.count))
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data()
            )
        }

        await store.recordReview(card: cards[3], rating: .good, duration: nil)

        XCTAssertEqual(uploadedBatchSizes.values, ["4"])
        XCTAssertTrue(
            try container.mainContext.fetch(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "review" }
                )
            ).isEmpty
        )
    }

    @MainActor
    func testNewCardCreateFlushesBeforeItsReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: offlineClient, context: container.mainContext)
        )

        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let card = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: card, rating: .good, duration: nil)
        let locallyReviewedCard = try XCTUnwrap(
            store.libraryCards.first { $0.id == card.id }
        )
        let serverCreatedAt = card.createdAt.addingTimeInterval(-60)
        let serverUpdatedAt = card.updatedAt.addingTimeInterval(1)
        let serverCard = StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: "server-note-id",
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer,
            state: card.state,
            answerAudioSource: "generated",
            createdAt: serverCreatedAt,
            updatedAt: serverUpdatedAt
        )
        let serverCardData = try StorageCodec.encoder.encode(serverCard)
        let decodedServerCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: serverCardData
        )
        let decodedReviewedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: StorageCodec.encoder.encode(locallyReviewedCard)
        )
        XCTAssertEqual(
            Set(
                try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                    .map(\.kind)
            ),
            ["cardCreate", "review"]
        )

        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let paths = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let status = path == "/api/study/session/start" ? 200 : 201
            let data: Data
            switch path {
            case "/api/study/cards":
                data = serverCardData
            case "/api/study/session/start":
                data = sessionData
            default:
                data = Data(#"{"data":[]}"#.utf8)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        await store.synchronize()

        XCTAssertEqual(
            paths.values,
            [
                "/api/study/cards",
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ]
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertEqual(record.serverUpdatedAt, decodedServerCard.updatedAt)
        XCTAssertEqual(storedCard.noteId, "server-note-id")
        XCTAssertEqual(storedCard.answerAudioSource, "generated")
        XCTAssertEqual(storedCard.createdAt, decodedServerCard.createdAt)
        XCTAssertEqual(storedCard.state, decodedReviewedCard.state)
        XCTAssertEqual(storedCard.updatedAt, decodedReviewedCard.updatedAt)
    }

    @MainActor
    func testSynchronizationPullsCanonicalInboundCardAndAdvancesCheckpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(
            LocalSyncState(userID: 1, cardCheckpoint: 1_234)
        )
        try container.mainContext.save()
        let serverCard = makeCard(
            id: "01J00000000000000000000AA",
            expression: "受信"
        )
        let secondServerCard = makeCard(
            id: "01J00000000000000000000AB",
            expression: "一括"
        )
        let serverCardID = serverCard.id
        let secondServerCardID = secondServerCard.id
        let serverCardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(serverCard)
        )
        let secondServerCardObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(secondServerCard)
        )
        let serverCardBatchData = try JSONSerialization.data(
            withJSONObject: ["cards": [serverCardObject, secondServerCardObject]]
        )
        let emptySession = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(emptySession)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let data: Data
            switch path {
            case "/api/sync/feed":
                let queryItems = URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems
                XCTAssertEqual(
                    queryItems?.first(where: { $0.name == "after_checkpoint" })?.value,
                    "1234"
                )
                XCTAssertEqual(
                    queryItems?.first(where: { $0.name == "per_page" })?.value,
                    "50"
                )
                data = Data(
                    """
                    {"data":[
                    {"checkpoint":1235,"resource_id":"\(serverCardID)","operation":"update"},
                    {"checkpoint":1236,"resource_id":"\(secondServerCardID)","operation":"create"}],
                    "meta":{"next_checkpoint":1236,"has_more":false}}
                    """.utf8
                )
            case "/api/study/cards/batch":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody(request)) as? [String: [String]]
                )
                XCTAssertEqual(body, ["ids": [serverCardID, secondServerCardID]])
                data = serverCardBatchData
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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

        await store.synchronize()

        XCTAssertEqual(
            paths.values,
            [
                "/api/sync/feed",
                "/api/study/cards/batch",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ]
        )
        XCTAssertEqual(Set(store.libraryCards.map(\.id)), Set([serverCardID, secondServerCardID]))
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            1_236
        )
        XCTAssertEqual(store.syncStatus, .idle)

        await store.synchronizeIfNeeded(maxAge: .seconds(60))

        XCTAssertEqual(
            paths.values,
            [
                "/api/sync/feed",
                "/api/study/cards/batch",
                "/api/study/known-kanji",
                "/api/study/session/start",
                "/api/study/offline-reserve",
            ],
            "A recent successful sync should suppress redundant Study-page refreshes."
        )
    }

    @MainActor
    func testRecentSessionRefreshDoesNotSuppressRetryOfTransientOutboxFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(
            id: "01J00000000000000000000AC",
            expression: "再試行"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let reviewAttempts = LockedCounter()
        let sessionRefreshes = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/card-review-events/batch":
                if reviewAttempts.next() <= 2 {
                    throw URLError(.networkConnectionLost)
                }
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data()
                )
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8)
                )
            case "/api/study/known-kanji":
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                    )
                )
            case "/api/study/session/start":
                _ = sessionRefreshes.next()
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    sessionData
                )
            case "/api/study/offline-reserve":
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                    )
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
        defer { store.deactivate() }

        await store.synchronize()
        let lastSuccessfulSync = try XCTUnwrap(store.lastSyncAt)
        XCTAssertEqual(sessionRefreshes.current, 1)

        await store.recordReview(card: reviewCard, rating: .good, duration: nil)
        await store.synchronize()

        XCTAssertEqual(reviewAttempts.current, 2)
        XCTAssertEqual(sessionRefreshes.current, 2)
        XCTAssertEqual(
            store.lastSyncAt,
            lastSuccessfulSync,
            "A successful session refresh must not advance full-sync freshness."
        )
        XCTAssertFalse(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(reviewAttempts.current, 3)
        XCTAssertEqual(sessionRefreshes.current, 3)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertGreaterThan(try XCTUnwrap(store.lastSyncAt), lastSuccessfulSync)
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testFailedImmediateRetryReturnsToSessionFreshnessThrottle() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(
            id: "01J00000000000000000000AD",
            expression: "抑制"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let reviewAttempts = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/card-review-events/batch":
                _ = reviewAttempts.next()
                throw URLError(.networkConnectionLost)
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8)
                )
            case "/api/study/known-kanji":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8)
                )
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    sessionData
                )
            case "/api/study/offline-reserve":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8)
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
        defer { store.deactivate() }

        await store.recordReview(card: reviewCard, rating: .good, duration: nil)
        await store.synchronize()
        await store.synchronizeIfNeeded(maxAge: .seconds(300))
        XCTAssertEqual(reviewAttempts.current, 3)

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(
            reviewAttempts.current,
            3,
            "A repeatedly failing outbox must return to the normal freshness throttle."
        )
    }

    @MainActor
    func testEagerReviewFlushFailureTriggersImmediateConditionalRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(
            id: "01J00000000000000000000AE",
            expression: "即時"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let reviewAttempts = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/card-review-events/batch":
                if reviewAttempts.next() == 1 {
                    throw URLError(.networkConnectionLost)
                }
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data()
                )
            case "/api/sync/feed":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8)
                )
            case "/api/study/known-kanji":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8)
                )
            case "/api/study/session/start":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    sessionData
                )
            case "/api/study/offline-reserve":
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(#"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8)
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
        defer { store.deactivate() }

        await store.synchronize()
        await store.recordReview(card: reviewCard, rating: .good, duration: nil)
        XCTAssertEqual(reviewAttempts.current, 1)

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(reviewAttempts.current, 2)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testOfflineReserveFromOldActivationCannotMergeAfterSameUserReactivation() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let staleReserveCard = makeCard(
            id: "reserve-from-old-activation",
            expression: "古い予備"
        )
        let emptySessionData = try sessionResponseData(cards: [])
        let staleReserveObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(staleReserveCard)
        )
        let staleReserveData = try JSONSerialization.data(withJSONObject: [
            "cards": [staleReserveObject],
            "reserveDays": 5,
            "generatedAt": "2026-07-25T12:00:00.000Z",
            "horizonEndsAt": "2026-07-30T12:00:00.000Z",
        ])
        let deferredReserve = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch request.url?.path {
            case "/api/sync/feed":
                completion(.success(Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))))
            case "/api/study/known-kanji":
                completion(.success(Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))))
            case "/api/study/session/start":
                completion(.success(Self.response(data: emptySessionData)))
            case "/api/study/offline-reserve":
                deferredReserve.hold(completion)
            default:
                completion(.failure(URLError(.badURL)))
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

        let syncTask = Task { await store.synchronize() }
        await waitUntil { deferredReserve.hasPendingResponse }

        store.activate(userID: 2)
        store.activate(userID: 1)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )

        deferredReserve.succeed(with: Self.response(data: staleReserveData))
        await syncTask.value

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
    }

    @MainActor
    func testOfflineReadinessCountsPreparedReserveCardsOutsideActiveSession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002B",
            expression: "予備"
        )
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = false
        record.mediaPreparedAt = .now
        container.mainContext.insert(record)
        try container.mainContext.save()
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
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
        defer { store.deactivate() }

        XCTAssertEqual(store.preparedCardCount, 1)
    }

    @MainActor
    func testMissingCardBatchEndpointFailsOnceWithoutIndividualFallbackRequests() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCardID = "01J0000000000000000000002C"
        let emptySession = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(emptySession)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let statusCode: Int
            let data: Data
            switch path {
            case "/api/sync/feed":
                statusCode = 200
                data = Data(
                    """
                    {"data":[
                    {"checkpoint":1,"resource_id":"\(serverCardID)","operation":"update"}],
                    "meta":{"next_checkpoint":1,"has_more":false}}
                    """.utf8
                )
            case "/api/study/cards/batch":
                statusCode = 404
                data = Data(#"{"message":"Not Found"}"#.utf8)
            case "/api/study/known-kanji":
                statusCode = 200
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                statusCode = 200
                data = sessionData
            case "/api/study/offline-reserve":
                statusCode = 200
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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
        defer { store.deactivate() }

        await store.synchronize()

        XCTAssertEqual(
            paths.values.count(where: { $0 == "/api/study/cards/batch" }),
            1
        )
        XCTAssertFalse(
            paths.values.contains(where: {
                $0.hasPrefix("/api/study/cards/") && $0 != "/api/study/cards/batch"
            })
        )
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            0
        )
        guard case .failed = store.syncStatus else {
            return XCTFail("The unavailable batch endpoint should fail this sync attempt.")
        }
    }

    @MainActor
    func testPartialCardBatchResponseResolvesWholePageWithoutPermanentRetryWedge() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000002D",
            expression: "保持"
        )
        let cardID = card.id
        let omittedCardIDs = [
            cardID,
            "01J0000000000000000000002E",
            "01J0000000000000000000002F",
            "01J0000000000000000000002G",
        ]
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.mediaPreparedAt = .now
        container.mainContext.insert(record)
        try container.mainContext.save()
        let emptySession = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(emptySession)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        let individualRequestCount = LockedCounter()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            let data: Data
            switch path {
            case "/api/sync/feed":
                let entries = omittedCardIDs.enumerated().map { index, resourceID in
                    """
                    {"checkpoint":\(index + 1),"resource_id":"\(resourceID)","operation":"update"}
                    """
                }.joined(separator: ",")
                data = Data(
                    """
                    {"data":[\(entries)],
                    "meta":{"next_checkpoint":4,"has_more":false}}
                    """.utf8
                )
            case "/api/study/cards/batch":
                data = Data(#"{"cards":[]}"#.utf8)
            case let path where path.hasPrefix("/api/study/cards/"):
                let attempt = individualRequestCount.next()
                let statusCode = attempt == 1 ? 500 : 404
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Unavailable"}"#.utf8)
                )
            case "/api/study/known-kanji":
                data = Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                )
            case "/api/study/session/start":
                data = sessionData
            case "/api/study/offline-reserve":
                data = Data(
                    #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
                )
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
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
        defer { store.deactivate() }

        await store.synchronize()

        XCTAssertEqual(store.libraryCards.map(\.id), [cardID])
        XCTAssertEqual(store.preparedCardCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            0
        )
        guard case .failed = store.syncStatus else {
            return XCTFail("A transient resolution failure should leave the sync page retryable.")
        }

        await store.synchronize()

        XCTAssertEqual(individualRequestCount.current, 5)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(
                container.mainContext.fetch(FetchDescriptor<LocalSyncState>()).first
            ).cardCheckpoint,
            4
        )
        XCTAssertEqual(store.syncStatus, .idle)
    }
}
