import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testOfflineReserveMetadataControlsReadinessAndSurvivesRelaunch() async throws {
        let suiteName = "StudyStoreSynchronizationTests.reserve-metadata.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = StudyCardCatalogSnapshotCache(defaults: defaults)
        let container = try Persistence.makeContainer(inMemory: true)
        let sessionData = try emptySessionResponseData(newCardsPerDay: 4)
        let horizonEndsAt = "2099-08-08T12:00:00.000Z"
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/known-kanji":
                return Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
            case "/api/study/offline-reserve":
                return Self.response(data: Data(
                    """
                    {"cards":[],"reserveDays":7,"generatedAt":"2099-08-01T12:00:00.000Z","horizonEndsAt":"\(horizonEndsAt)"}
                    """.utf8
                ))
            default:
                throw URLError(.badURL)
            }
        }
        let store = makeSynchronizationStore(container: container, client: client, cache: cache)

        await store.synchronize()

        XCTAssertEqual(store.offlineReserveDays, 7)
        XCTAssertTrue(store.offlineReserveIsCurrent)
        XCTAssertEqual(store.offlineReadinessTarget, 28)
        XCTAssertEqual(
            store.offlineReserveMetadata?.horizonEndsAt,
            ISO8601Milliseconds.date(from: horizonEndsAt)
        )
        store.deactivate()

        let relaunched = makeSynchronizationStore(container: container, client: client, cache: cache)
        defer { relaunched.deactivate() }

        XCTAssertEqual(relaunched.offlineReserveDays, 7)
        XCTAssertTrue(relaunched.offlineReserveIsCurrent)
        XCTAssertEqual(relaunched.offlineReadinessTarget, 28)

        relaunched.offlineReserveMetadata = StudyOfflineReserveMetadata(
            reserveDays: 30,
            generatedAt: .distantPast,
            horizonEndsAt: .distantPast
        )
        XCTAssertFalse(relaunched.offlineReserveIsCurrent)
        XCTAssertEqual(relaunched.offlineReadinessTarget, 0)
    }

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
        let store = makeSynchronizationStore(container: container, client: client)

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
        let store = makeSynchronizationStore(container: container, client: client)
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
        let store = makeSynchronizationStore(container: container, client: offlineClient)

        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let card = try XCTUnwrap(store.cards.first)
        await store.recordReview(card: card, rating: .good, duration: nil)
        let locallyReviewedCard = try XCTUnwrap(
            store.libraryCards.first { $0.id == card.id }
        )
        let serverCard = makeServerCard(from: card)
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

        let sessionData = try emptySessionResponseData()
        let paths = LockedRequestPaths()
        installCardCreateHandler(
            serverCardData: serverCardData,
            sessionData: sessionData,
            paths: paths
        )

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
        let sessionData = try emptySessionResponseData()
        let paths = LockedRequestPaths()
        let client = makeCanonicalSyncClient(
            cardIDs: [serverCardID, secondServerCardID],
            cardBatchData: serverCardBatchData,
            sessionData: sessionData,
            paths: paths
        )
        let store = makeSynchronizationStore(container: container, client: client)

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
        let sessionData = try emptySessionResponseData()
        let reviewAttempts = LockedCounter()
        let sessionRefreshes = LockedCounter()
        let client = makeReviewRetryClient(
            sessionData: sessionData,
            reviewAttempts: reviewAttempts,
            failures: 2,
            sessionRefreshes: sessionRefreshes
        )
        let store = makeSynchronizationStore(container: container, client: client)
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
        let scenario = try makeReviewRetryScenario(failures: .max)
        let store = scenario.store
        defer { store.deactivate() }

        await store.recordReview(card: scenario.card, rating: .good, duration: nil)
        await store.synchronize()
        await store.synchronizeIfNeeded(maxAge: .seconds(300))
        XCTAssertEqual(scenario.attempts.current, 3)

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(
            scenario.attempts.current,
            3,
            "A repeatedly failing outbox must return to the normal freshness throttle."
        )
    }

    @MainActor
    func testEagerReviewFlushFailureTriggersImmediateConditionalRetry() async throws {
        let scenario = try makeReviewRetryScenario(failures: 1)
        let store = scenario.store
        defer { store.deactivate() }

        await store.synchronize()
        await store.recordReview(card: scenario.card, rating: .good, duration: nil)
        XCTAssertEqual(scenario.attempts.current, 1)

        await store.synchronizeIfNeeded(maxAge: .seconds(300))

        XCTAssertEqual(scenario.attempts.current, 2)
        XCTAssertTrue(
            try scenario.container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
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
        let store = makeSynchronizationStore(container: container, client: client)

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
        let store = makeSynchronizationStore(container: container, client: client)
        defer { store.deactivate() }

        XCTAssertEqual(store.preparedCardCount, 1)
    }

    @MainActor
    func testMissingCardBatchEndpointFailsOnceWithoutIndividualFallbackRequests() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let serverCardID = "01J0000000000000000000002C"
        let sessionData = try emptySessionResponseData()
        let paths = LockedRequestPaths()
        let client = makeMissingBatchClient(
            cardID: serverCardID,
            sessionData: sessionData,
            paths: paths
        )
        let store = makeSynchronizationStore(container: container, client: client)
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
        let sessionData = try emptySessionResponseData()
        let individualRequestCount = LockedCounter()
        let client = makePartialBatchClient(
            omittedCardIDs: omittedCardIDs,
            sessionData: sessionData,
            individualRequestCount: individualRequestCount
        )
        let store = makeSynchronizationStore(container: container, client: client)
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

    @MainActor
    private func makeSynchronizationStore(
        container: ModelContainer,
        client: APIClient,
        cache: StudyCardCatalogSnapshotCache? = nil
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
            cardCatalogSnapshotCache: cache
        )
    }

    @MainActor
    private func makeReviewRetryClient(
        sessionData: Data,
        reviewAttempts: LockedCounter,
        failures: Int,
        sessionRefreshes: LockedCounter? = nil
    ) -> APIClient {
        makeClient { request in
            if request.url?.path == "/api/card-review-events/batch" {
                guard reviewAttempts.next() > failures else {
                    throw URLError(.networkConnectionLost)
                }
                return Self.response(statusCode: 201, data: Data())
            }
            if request.url?.path == "/api/study/session/start" {
                _ = sessionRefreshes?.next()
            }
            return try Self.standardSynchronizationResponse(
                for: request,
                sessionData: sessionData
            )
        }
    }

    private func installCardCreateHandler(
        serverCardData: Data,
        sessionData: Data,
        paths: LockedRequestPaths
    ) {
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            let status = path == "/api/study/session/start" ? 200 : 201
            let data = switch path {
            case "/api/study/cards": serverCardData
            case "/api/study/session/start": sessionData
            default: Data(#"{"data":[]}"#.utf8)
            }
            return Self.response(statusCode: status, data: data)
        }
    }

    @MainActor
    private func makeServerCard(from card: StudyCard) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: "server-note-id",
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer,
            state: card.state,
            answerAudioSource: "generated",
            createdAt: card.createdAt.addingTimeInterval(-60),
            updatedAt: card.updatedAt.addingTimeInterval(1)
        )
    }

    @MainActor
    private func makeCanonicalSyncClient(
        cardIDs: [String],
        cardBatchData: Data,
        sessionData: Data,
        paths: LockedRequestPaths
    ) -> APIClient {
        makeSynchronizationClient(sessionData: sessionData, paths: paths) { request in
            switch request.url?.path {
            case "/api/sync/feed":
                try Self.assertSyncFeedQuery(request)
                return Self.response(data: Self.canonicalSyncFeedData(cardIDs: cardIDs))
            case "/api/study/cards/batch":
                try Self.assertCardBatchRequest(request, cardIDs: cardIDs)
                return Self.response(data: cardBatchData)
            default:
                return nil
            }
        }
    }

    private static func assertSyncFeedQuery(_ request: URLRequest) throws {
        let queryItems = URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(queryItems?.first(where: { $0.name == "after_checkpoint" })?.value, "1234")
        XCTAssertEqual(queryItems?.first(where: { $0.name == "per_page" })?.value, "50")
    }

    private static func assertCardBatchRequest(_ request: URLRequest, cardIDs: [String]) throws {
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody(request)) as? [String: [String]]
        )
        XCTAssertEqual(body, ["ids": cardIDs])
    }

    @MainActor
    private func makeMissingBatchClient(
        cardID: String,
        sessionData: Data,
        paths: LockedRequestPaths
    ) -> APIClient {
        makeSynchronizationClient(sessionData: sessionData, paths: paths) { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.singleCardSyncFeedData(cardID: cardID))
            case "/api/study/cards/batch":
                return Self.response(statusCode: 404, data: Data(#"{"message":"Not Found"}"#.utf8))
            default:
                return nil
            }
        }
    }

    @MainActor
    private func makeSynchronizationClient(
        sessionData: Data,
        paths: LockedRequestPaths,
        customResponse: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)?
    ) -> APIClient {
        makeClient { request in
            paths.append(request.url?.path ?? "")
            if let response = try customResponse(request) {
                return response
            }
            return try Self.standardSynchronizationResponse(for: request, sessionData: sessionData)
        }
    }

    private struct ReviewRetryScenario {
        let container: ModelContainer
        let card: StudyCard
        let attempts: LockedCounter
        let store: StudyStore
    }

    @MainActor
    private func makeReviewRetryScenario(failures: Int) throws -> ReviewRetryScenario {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "review-retry-card", expression: "再試行")
        let attempts = LockedCounter()
        let client = makeReviewRetryClient(
            sessionData: try emptySessionResponseData(),
            reviewAttempts: attempts,
            failures: failures
        )
        return ReviewRetryScenario(
            container: container,
            card: card,
            attempts: attempts,
            store: makeSynchronizationStore(container: container, client: client)
        )
    }

    @MainActor
    private func makePartialBatchClient(
        omittedCardIDs: [String],
        sessionData: Data,
        individualRequestCount: LockedCounter
    ) -> APIClient {
        makeClient { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/sync/feed":
                return Self.response(data: Self.syncFeedData(cardIDs: omittedCardIDs))
            case "/api/study/cards/batch":
                return Self.response(data: Data(#"{"cards":[]}"#.utf8))
            case let path where path.hasPrefix("/api/study/cards/"):
                let status = individualRequestCount.next() == 1 ? 500 : 404
                return Self.response(statusCode: status, data: Data(#"{"message":"Unavailable"}"#.utf8))
            default:
                return try Self.standardSynchronizationResponse(for: request, sessionData: sessionData)
            }
        }
    }

    private static func standardSynchronizationResponse(
        for request: URLRequest,
        sessionData: Data
    ) throws -> (HTTPURLResponse, Data) {
        switch request.url?.path {
        case "/api/sync/feed":
            return Self.response(data: Self.emptySyncFeedData)
        case "/api/study/known-kanji":
            return Self.response(data: Self.emptyKnownKanjiData)
        case "/api/study/session/start":
            return Self.response(data: sessionData)
        case "/api/study/offline-reserve":
            return Self.response(data: Self.emptyOfflineReserveData)
        default:
            throw URLError(.badURL)
        }
    }

    @MainActor
    private func emptySessionResponseData(newCardsPerDay: Int = 10) throws -> Data {
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: newCardsPerDay,
                newCardsAvailableToday: 0
            ),
            cards: []
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        return try JSONSerialization.data(withJSONObject: ["data": object])
    }

    private static let emptySyncFeedData = Data(
        #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
    )
    private static let emptyKnownKanjiData = Data(
        #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
    )
    private static let emptyOfflineReserveData = Data(
        #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00.000Z","horizonEndsAt":"2026-07-30T12:00:00.000Z"}"#.utf8
    )

    private static func canonicalSyncFeedData(cardIDs: [String]) -> Data {
        Data(
            """
            {"data":[
            {"checkpoint":1235,"resource_id":"\(cardIDs[0])","operation":"update"},
            {"checkpoint":1236,"resource_id":"\(cardIDs[1])","operation":"create"}],
            "meta":{"next_checkpoint":1236,"has_more":false}}
            """.utf8
        )
    }

    private static func singleCardSyncFeedData(cardID: String) -> Data {
        Data(
            """
            {"data":[
            {"checkpoint":1,"resource_id":"\(cardID)","operation":"update"}],
            "meta":{"next_checkpoint":1,"has_more":false}}
            """.utf8
        )
    }

    private static func syncFeedData(cardIDs: [String]) -> Data {
        let entries = cardIDs.enumerated().map { index, resourceID in
            """
            {"checkpoint":\(index + 1),"resource_id":"\(resourceID)","operation":"update"}
            """
        }.joined(separator: ",")
        return Data(
            """
            {"data":[\(entries)],
            "meta":{"next_checkpoint":\(cardIDs.count),"has_more":false}}
            """.utf8
        )
    }
}
