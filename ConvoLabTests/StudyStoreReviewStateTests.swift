import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

private struct ReviewStateCardSeed {
    let id: String
    let expression: String
    var variantGroupID: String? = nil
    var variantStatus: String? = nil
    var scheduler: JSONValue? = nil
}

private struct ReviewStateFixture {
    let container: ModelContainer
    let card: StudyCard
}

private struct MasteryAnimationExpectation {
    let from: StudyMasteryLevel
    let to: StudyMasteryLevel
    let passed: Bool
}

private enum ProgressionReviewResult {
    case accepted
    case locked
    case mixedWithRejectedEvent(String)
}

private final class ProgressionReviewServer: @unchecked Sendable {
    let paths = LockedRequestPaths()
    private let result: ProgressionReviewResult
    private let sessionData: Data
    private let syncFails: Bool
    private let sessionStatus: Int

    init(
        result: ProgressionReviewResult,
        sessionData: Data,
        syncFails: Bool = false,
        sessionStatus: Int = 200
    ) {
        self.result = result
        self.sessionData = sessionData
        self.syncFails = syncFails
        self.sessionStatus = sessionStatus
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        paths.append(path)
        switch path {
        case "/api/card-review-events/batch":
            return try reviewResponse(for: request)
        case "/api/sync/feed":
            return try syncResponse()
        case "/api/study/session/start":
            return StudyStoreTests.response(statusCode: sessionStatus, data: sessionData)
        default:
            XCTFail("Unexpected request: \(path)")
            throw URLError(.badServerResponse)
        }
    }

    private func syncResponse() throws -> (HTTPURLResponse, Data) {
        if syncFails { throw URLError(.notConnectedToInternet) }
        return StudyStoreTests.response(data: Data(
            #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
        ))
    }

    private func reviewResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        switch result {
        case .accepted:
            return StudyStoreTests.response(statusCode: 204, data: Data())
        case .locked:
            return lockedResponse()
        case .mixedWithRejectedEvent(let rejectedID):
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            let events = try XCTUnwrap(body["events"] as? [[String: Any]])
            let eventIDs = events.compactMap { $0["id"] as? String }
            if eventIDs.count > 1 {
                return StudyStoreTests.response(
                    statusCode: 422,
                    data: Data(#"{"message":"Mixed review failure"}"#.utf8)
                )
            }
            if eventIDs == [rejectedID] {
                return StudyStoreTests.response(
                    statusCode: 422,
                    data: Data(#"{"message":"Invalid review"}"#.utf8)
                )
            }
            return lockedResponse()
        }
    }

    private func lockedResponse() -> (HTTPURLResponse, Data) {
        StudyStoreTests.response(
            statusCode: 409,
            data: Data(#"{"message":"Card is locked by a learning progression."}"#.utf8)
        )
    }
}

private final class DeferredProgressionReviewServer: @unchecked Sendable {
    let paths = LockedRequestPaths()
    let deferredPull = LockedDeferredResponse()
    private let sessionData: Data

    init(sessionData: Data) {
        self.sessionData = sessionData
    }

    func handle(
        request: URLRequest,
        completion: @escaping MockURLProtocol.DeferredCompletion
    ) {
        let path = request.url?.path ?? ""
        paths.append(path)
        switch path {
        case "/api/card-review-events/batch":
            completion(.success(StudyStoreTests.response(statusCode: 204, data: Data())))
        case "/api/sync/feed":
            deferredPull.hold(completion)
        case "/api/study/session/start":
            completion(.success(StudyStoreTests.response(data: sessionData)))
        default:
            XCTFail("Unexpected request: \(path)")
            completion(.failure(URLError(.badServerResponse)))
        }
    }
}

extension StudyStoreTests {
    @MainActor
    func testProgressionLockRejectionClearsFailureAndRevalidatesQueue() async throws {
        let fixture = try makeReviewStateFixture(.init(
            id: "01J000000000000000000000PL",
            expression: "進行中",
            variantGroupID: "progression-family",
            variantStatus: "available"
        ))
        let server = ProgressionReviewServer(
            result: .locked,
            sessionData: try sessionResponseData(cards: [])
        )
        let client = makeClient { try server.response(for: $0) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        let result = await store.recordReviewResult(
            card: fixture.card,
            rating: .good,
            duration: nil
        )

        await waitUntil { server.paths.values.count == 4 }
        XCTAssertNil(result)
        XCTAssertEqual(
            server.paths.values,
            [
                "/api/card-review-events/batch",
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertNil(store.masteryAnimation)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        XCTAssertTrue(
            try fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let record = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testProgressionLockRollbackSurvivesUnrelatedQuarantinedReview() async throws {
        let fixture = try makeReviewStateFixture(.init(
            id: "01J000000000000000000000PM",
            expression: "混在",
            variantGroupID: "progression-family",
            variantStatus: "available"
        ))
        let oldEvent = ReviewBatchRequest.Event(
            id: "old-invalid-event",
            cardID: "old-invalid-card",
            rating: .good,
            reviewedAt: Date(timeIntervalSince1970: 100),
            durationMilliseconds: nil,
            clientEventID: "old-client-event",
            deviceID: "old-device",
            clientCreatedAt: Date(timeIntervalSince1970: 100)
        )
        let oldMutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: oldEvent.cardID,
            payload: try StorageCodec.encoder.encode(PendingReviewPayload(
                event: oldEvent,
                cardBefore: PendingReviewCardState(id: oldEvent.cardID, failedAt: nil)
            ))
        )
        oldMutation.createdAt = Date(timeIntervalSince1970: 100)
        fixture.container.mainContext.insert(oldMutation)
        try fixture.container.mainContext.save()
        let server = ProgressionReviewServer(
            result: .mixedWithRejectedEvent(oldEvent.id),
            sessionData: try sessionResponseData(cards: [])
        )
        let client = makeClient { try server.response(for: $0) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        let result = await store.recordReviewResult(
            card: fixture.card,
            rating: .good,
            duration: nil
        )

        await waitUntil { server.paths.values.count == 5 }
        XCTAssertNil(result)
        XCTAssertEqual(
            server.paths.values,
            [
                "/api/card-review-events/batch",
                "/api/card-review-events/batch",
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertNil(store.masteryAnimation)
        XCTAssertEqual(store.failedStudyChanges.count, 1)
        XCTAssertEqual(store.failedStudyChanges.first?.kind, .review)
        let pending = try fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.id), [oldMutation.id])
        XCTAssertEqual(pending.first?.lastError, "HTTP 422: Invalid review")
        let record = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testAcceptedProgressionReviewReplacesRemainingCachedQueue() async throws {
        let stale = makeCard(
            id: "01J000000000000000000000PB",
            expression: "古い待ち行列",
            variantGroupID: "progression-family",
            variantStatus: "available"
        )
        let authoritative = makeCard(
            id: "01J000000000000000000000PC",
            expression: "次のカード"
        )
        let fixture = try makeReviewStateFixture(
            .init(
                id: "01J000000000000000000000PA",
                expression: "現在",
                variantGroupID: "progression-family",
                variantStatus: "available"
            ),
            additionalCards: [stale]
        )
        let server = ProgressionReviewServer(
            result: .accepted,
            sessionData: try sessionResponseData(cards: [authoritative])
        )
        let client = makeClient { try server.response(for: $0) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        let result = await store.recordReviewResult(
            card: fixture.card,
            rating: .good,
            duration: nil
        )

        for _ in 0..<100 where store.cards.map(\.id) != [authoritative.id] {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(
            server.paths.values,
            [
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
        XCTAssertEqual(store.cards.map(\.id), [authoritative.id])
        XCTAssertFalse(store.cards.contains { $0.id == stale.id })
        XCTAssertEqual(store.sessionCompletedCardIDs, [fixture.card.id])
    }

    @MainActor
    func testProgressionRevalidationPreservesEarlierPullFailure() async throws {
        let fixture = try makeReviewStateFixture(.init(
            id: "01J000000000000000000000PE",
            expression: "失敗順序",
            variantGroupID: "progression-family",
            variantStatus: "available"
        ))
        let server = ProgressionReviewServer(
            result: .accepted,
            sessionData: Data(#"{"message":"Session revalidation failed"}"#.utf8),
            syncFails: true,
            sessionStatus: 422
        )
        let client = makeClient { try server.response(for: $0) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        _ = await store.recordReviewResult(
            card: fixture.card,
            rating: .good,
            duration: nil
        )

        await waitUntil { server.paths.values.count == 3 }
        XCTAssertEqual(
            server.paths.values,
            [
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
        XCTAssertEqual(store.syncStatus, .offline)
    }

    @MainActor
    func testAcceptedProgressionReviewDoesNotWaitForQueueRevalidation() async throws {
        let fixture = try makeReviewStateFixture(.init(
            id: "01J000000000000000000000PF",
            expression: "すぐ終わる",
            variantGroupID: "progression-family",
            variantStatus: "available"
        ))
        let server = DeferredProgressionReviewServer(
            sessionData: try sessionResponseData(cards: [])
        )
        let client = makeDeferredClient { server.handle(request: $0, completion: $1) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        let result = await store.recordReviewResult(
            card: fixture.card,
            rating: .good,
            duration: nil
        )

        XCTAssertNotNil(result)
        await server.deferredPull.waitUntilPending()
        XCTAssertEqual(
            server.paths.values,
            ["/api/card-review-events/batch", "/api/sync/feed"]
        )

        server.deferredPull.succeed(with: Self.response(data: Data(
            #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
        )))
        await waitUntil { server.paths.values.count == 3 }
    }

    @MainActor
    func testProgressionRevalidationCannotReplaceANewerReviewSession() async throws {
        let current = makeCard(
            id: "01J000000000000000000000PH",
            expression: "現在のセッション"
        )
        let fixture = try makeReviewStateFixture(.init(
            id: "01J000000000000000000000PG",
            expression: "前のセッション",
            variantGroupID: "progression-family",
            variantStatus: "available"
        ))
        let server = DeferredProgressionReviewServer(
            sessionData: try sessionResponseData(cards: [current])
        )
        let client = makeDeferredClient { server.handle(request: $0, completion: $1) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        let result = await store.recordReviewResult(
            card: fixture.card,
            rating: .good,
            duration: nil
        )
        XCTAssertNotNil(result)
        await server.deferredPull.waitUntilPending()

        try await store.refreshSession()
        XCTAssertEqual(store.cards.map(\.id), [current.id])

        server.deferredPull.succeed(with: Self.response(data: Data(
            #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
        )))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.cards.map(\.id), [current.id])
        XCTAssertEqual(
            server.paths.values,
            [
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
    }

    @MainActor
    func testOfflineReviewedCardStaysOutOfQueueAfterRelaunch() async throws {
        let fixture = try makeReviewStateFixture(.init(
            id: "01J00000000000000000000018",
            expression: "鳥"
        ))
        let deliveryAttempts = LockedCounter()
        let client = makeClient { _ in
            _ = deliveryAttempts.next()
            throw URLError(.notConnectedToInternet)
        }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        await store.recordReview(card: fixture.card, rating: .good, duration: .milliseconds(750))
        XCTAssertEqual(deliveryAttempts.current, 1)
        XCTAssertEqual(store.pendingOfflineReviewCount, 1)
        let relaunchedStore = makeReviewStateStore(container: fixture.container, client: client)
        XCTAssertEqual(relaunchedStore.pendingOfflineReviewCount, 1)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [fixture.card.id])
        XCTAssertEqual(relaunchedStore.libraryCards.map(\.id), [fixture.card.id])
        let record = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertFalse(record.isInActiveSession)
        let reviewMutation = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "review" })
        )
        let storedReview = try JSONSerialization.jsonObject(
            with: reviewMutation.payload
        ) as? [String: Any]
        let event = try XCTUnwrap(storedReview?["event"])
        let eventData = try JSONSerialization.data(withJSONObject: event)
        let review = try StorageCodec.decoder.decode(
            ReviewBatchRequest.Event.self,
            from: eventData
        )
        XCTAssertEqual(review.durationMilliseconds, 750)
    }

    @MainActor
    func testInjectedReviewDeliveryFailurePreservesReviewAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "ConvoLabReviewOutbox-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "ReviewOutbox.store")
        let card = makeCard(
            id: "01J000000000000000000000IF",
            expression: "保留"
        )
        let deliveryAttempts = LockedCounter()

        do {
            let container = try Persistence.makeContainer(storeURL: storeURL)
            container.mainContext.insert(
                LocalCardRecord(
                    card: card,
                    userID: 1,
                    queueIndex: 0,
                    payload: try StorageCodec.encoder.encode(card)
                )
            )
            try container.mainContext.save()
            let client = makeClient { _ in
                XCTFail("Injected delivery must replace the network boundary")
                throw URLError(.unknown)
            }
            let store = makeReviewStateStore(
                container: container,
                client: client,
                reviewFlush: {
                    _ = deliveryAttempts.next()
                    throw URLError(.notConnectedToInternet)
                }
            )
            XCTAssertEqual(store.pendingOfflineReviewCount, 0)
            let countChanged = expectation(
                description: "Pending offline review count observation changed"
            )
            withObservationTracking {
                _ = store.pendingOfflineReviewCount
            } onChange: {
                countChanged.fulfill()
            }

            await store.recordReview(card: card, rating: .good, duration: nil)

            await fulfillment(of: [countChanged], timeout: 1)
            XCTAssertEqual(deliveryAttempts.current, 1)
            XCTAssertEqual(store.pendingOfflineReviewCount, 1)
        }

        let relaunchedContainer = try Persistence.makeContainer(storeURL: storeURL)
        let relaunchedClient = makeClient { _ in
            XCTFail("Relaunch construction must not perform delivery")
            throw URLError(.unknown)
        }
        let relaunchedStore = makeReviewStateStore(
            container: relaunchedContainer,
            client: relaunchedClient
        )
        XCTAssertEqual(relaunchedStore.pendingOfflineReviewCount, 1)
    }

    @MainActor
    func testReviewOverviewSnapshotFlushesWithoutWaitingForNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000019",
            expression: "魚"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        container.mainContext.insert(LocalStudyOverviewSnapshot(
            userID: 1,
            payload: try StorageCodec.encoder.encode(StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 0,
                jlptMastery: StudyJLPTMastery(
                    n5: StudyJLPTLevelMastery(
                        vocabulary: StudyJLPTMasteryMetric(
                            masteryPercent: 8,
                            covered: 83,
                            total: 684
                        ),
                        grammar: StudyJLPTMasteryMetric(
                            masteryPercent: 46,
                            covered: 36,
                            total: 77
                        )
                    )
                )
            ))
        ))
        try container.mainContext.save()
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

        await store.recordReview(card: card, rating: .good, duration: nil)
        store.persistCachedState()

        let verificationContext = ModelContext(container)
        let snapshot = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<LocalStudyOverviewSnapshot>()).first
        )
        let restored = try StorageCodec.decoder.decode(
            StudyOverview.self,
            from: snapshot.payload
        )
        XCTAssertEqual(restored.dueCount, 0)
        XCTAssertEqual(restored.jlptMastery?.n5.vocabulary.masteryPercent, 8)
        XCTAssertEqual(restored.jlptMastery?.n5.grammar.masteryPercent, 46)
    }

    @MainActor
    func testReviewFromStaleSnapshotUpdatesCanonicalRecordWithoutDuplicate() async throws {
        let clientID = "01J000000000000000000000RV"
        let canonicalID = clientID.lowercased()
        let canonicalCard = makeCard(
            id: canonicalID,
            expression: "現在のローカル内容",
            queueState: "review"
        )
        let fixture = try makeReviewStateFixture(
            .init(id: clientID, expression: "古い識別子"),
            storesPrimary: false,
            additionalCards: [canonicalCard]
        )
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        let eventID = await store.recordReview(
            card: fixture.card,
            rating: .again,
            duration: nil,
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNotNil(eventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [canonicalID])
        let records = try fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, canonicalID)
        XCTAssertFalse(record.isInActiveSession)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.id, canonicalID)
        XCTAssertEqual(persisted.promptText, "現在のローカル内容")
        XCTAssertNotEqual(persisted.state, canonicalCard.state)
        let review = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>())
                .first(where: { $0.kind == "review" })
        )
        XCTAssertEqual(review.resourceID, canonicalID)
        let pendingReview = try StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: review.payload
        )
        XCTAssertEqual(pendingReview.event.cardID, canonicalID)
        XCTAssertEqual(pendingReview.cardBefore.id, canonicalID)
        XCTAssertEqual(store.sessionFailureCount, 1)

        try await store.undoReview(
            eventID: try XCTUnwrap(eventID),
            cardBefore: fixture.card
        )

        XCTAssertEqual(store.sessionFailureCount, 0)
        XCTAssertEqual(store.cards.map(\.id), [canonicalID])
        XCTAssertEqual(store.cards.first?.promptText, "現在のローカル内容")
    }

    @MainActor
    func testPendingReviewFiltersCaseCanonicalizedCardsFromEverySession() async throws {
        let fixture = try makeReviewStateFixture(.init(
            id: "01J0000000000000000000001R",
            expression: "保留"
        ))
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = makeReviewStateStore(container: fixture.container, client: client)

        await store.recordReview(card: fixture.card, rating: .good, duration: nil)

        let serverCard = makeCard(
            id: fixture.card.id.lowercased(),
            expression: "保留"
        )
        let sessionData = try sessionResponseData(cards: [serverCard])
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            XCTAssertTrue(
                ["/api/study/session/start", "/api/study/lessons/start"]
                    .contains(path)
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                sessionData
            )
        }
        let relaunchedStore = makeReviewStateStore(container: fixture.container, client: client)

        try await relaunchedStore.refreshSession()
        XCTAssertTrue(relaunchedStore.cards.isEmpty)

        try await relaunchedStore.refreshLessons()
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
    }

    @MainActor
    func testMasteryAnimationRemainsVisibleAfterTheReviewedCardAdvances() async throws {
        let fixture = try makeMasteryReviewFixture()
        let sessionData = try sessionResponseData(cards: [fixture.card])
        let client = makeClient { request in
            if request.url?.path == "/api/study/session/start" {
                return Self.response(data: sessionData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeReviewStateStore(container: fixture.container, client: client)
        try await store.refreshSession()

        let recordedEventID = await store.recordReview(
            card: fixture.card,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)

        XCTAssertTrue(store.cards.isEmpty)
        assertMasteryAnimation(
            in: store,
            for: fixture.card,
            expected: .init(from: .master, to: .enlightened, passed: true)
        )

        try await store.undoReview(eventID: eventID, cardBefore: fixture.card)

        XCTAssertNil(store.masteryAnimation)

        let sameStageEventID = await store.recordReview(
            card: fixture.card,
            rating: .hard,
            duration: nil
        )

        assertMasteryAnimation(
            in: store,
            for: fixture.card,
            expected: .init(from: .master, to: .master, passed: true)
        )

        try await store.undoReview(
            eventID: try XCTUnwrap(sameStageEventID),
            cardBefore: fixture.card
        )

        _ = await store.recordReview(
            card: fixture.card,
            rating: .again,
            duration: nil
        )

        assertMasteryAnimation(
            in: store,
            for: fixture.card,
            expected: .init(from: .master, to: .apprentice, passed: false)
        )
    }

    @MainActor
    private func makeReviewStateFixture(
        _ seed: ReviewStateCardSeed,
        storesPrimary: Bool = true,
        additionalCards: [StudyCard] = []
    ) throws -> ReviewStateFixture {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: seed.id,
            expression: seed.expression,
            scheduler: seed.scheduler,
            variantGroupID: seed.variantGroupID,
            variantStatus: seed.variantStatus
        )
        let storedCards = (storesPrimary ? [card] : []) + additionalCards
        for (index, storedCard) in storedCards.enumerated() {
            container.mainContext.insert(LocalCardRecord(
                card: storedCard,
                userID: 1,
                queueIndex: index,
                payload: try StorageCodec.encoder.encode(storedCard)
            ))
        }
        try container.mainContext.save()
        return .init(container: container, card: card)
    }

    @MainActor
    private func makeReviewStateStore(
        container: ModelContainer,
        client: APIClient
    ) -> StudyStore {
        StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
        )
    }

    @MainActor
    private func makeReviewStateStore(
        container: ModelContainer,
        client: APIClient,
        reviewFlush: @escaping () async throws -> Void
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
            reviewEventOutboxFlushOverride: reviewFlush
        )
    }

    @MainActor
    private func assertMasteryAnimation(
        in store: StudyStore,
        for card: StudyCard,
        expected: MasteryAnimationExpectation
    ) {
        XCTAssertEqual(store.masteryAnimation?.card.id, card.id)
        XCTAssertEqual(store.masteryAnimation?.fromLevel, expected.from.rawValue)
        XCTAssertEqual(store.masteryAnimation?.toLevel, expected.to.rawValue)
        XCTAssertEqual(store.masteryAnimation?.passed, expected.passed)
    }

    @MainActor
    private func makeMasteryReviewFixture() throws -> ReviewStateFixture {
        try makeReviewStateFixture(.init(
            id: "01J0000000000000000000001U",
            expression: "復習",
            scheduler: .object([
                "due": .string("2026-04-12T00:00:00.000Z"),
                "stability": .number(54.1885),
                "difficulty": .number(9.317),
                "elapsed_days": .number(59),
                "scheduled_days": .number(59),
                "learning_steps": .number(0),
                "reps": .number(12),
                "lapses": .number(1),
                "state": .number(2),
                "last_review": .string("2026-02-12T13:01:42.000Z"),
            ])
        ))
    }
}
