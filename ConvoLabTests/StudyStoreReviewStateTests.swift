import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testProgressionLockRejectionClearsFailureAndRevalidatesQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PL",
            expression: "進行中",
            variantGroupID: "progression-family",
            variantStatus: "available"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()
        let paths = LockedRequestPaths()
        let emptySessionData = try sessionResponseData(cards: [])
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/card-review-events/batch":
                return Self.response(
                    statusCode: 409,
                    data: Data(
                        #"{"message":"Card is locked by a learning progression."}"#.utf8
                    )
                )
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: emptySessionData)
            default:
                XCTFail("Unexpected request: \(path)")
                throw URLError(.badServerResponse)
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

        let result = await store.recordReviewResult(
            card: card,
            rating: .good,
            duration: nil
        )

        XCTAssertNil(result)
        XCTAssertEqual(
            paths.values,
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
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testProgressionLockRollbackSurvivesUnrelatedQuarantinedReview() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PM",
            expression: "混在",
            variantGroupID: "progression-family",
            variantStatus: "available"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
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
        container.mainContext.insert(oldMutation)
        try container.mainContext.save()
        let oldEventID = oldEvent.id
        let paths = LockedRequestPaths()
        let emptySessionData = try sessionResponseData(cards: [])
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/card-review-events/batch":
                let body = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: requestBody(request))
                        as? [String: Any]
                )
                let events = try XCTUnwrap(body["events"] as? [[String: Any]])
                let eventIDs = events.compactMap { $0["id"] as? String }
                if eventIDs.count > 1 {
                    return Self.response(
                        statusCode: 422,
                        data: Data(#"{"message":"Mixed review failure"}"#.utf8)
                    )
                }
                if eventIDs == [oldEventID] {
                    return Self.response(
                        statusCode: 422,
                        data: Data(#"{"message":"Invalid review"}"#.utf8)
                    )
                }
                return Self.response(
                    statusCode: 409,
                    data: Data(
                        #"{"message":"Card is locked by a learning progression."}"#.utf8
                    )
                )
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: emptySessionData)
            default:
                XCTFail("Unexpected request: \(path)")
                throw URLError(.badServerResponse)
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

        let result = await store.recordReviewResult(
            card: card,
            rating: .good,
            duration: nil
        )

        XCTAssertNil(result)
        XCTAssertEqual(
            paths.values,
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
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.map(\.id), [oldMutation.id])
        XCTAssertEqual(pending.first?.lastError, "HTTP 422: Invalid review")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testAcceptedProgressionReviewReplacesRemainingCachedQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewed = makeCard(
            id: "01J000000000000000000000PA",
            expression: "現在",
            variantGroupID: "progression-family",
            variantStatus: "available"
        )
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
        for (index, card) in [reviewed, stale].enumerated() {
            container.mainContext.insert(LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: index,
                payload: try StorageCodec.encoder.encode(card)
            ))
        }
        try container.mainContext.save()
        let paths = LockedRequestPaths()
        let sessionData = try sessionResponseData(cards: [authoritative])
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/card-review-events/batch":
                return Self.response(statusCode: 204, data: Data())
            case "/api/sync/feed":
                return Self.response(data: Data(
                    #"{"data":[],"meta":{"next_checkpoint":0,"has_more":false}}"#.utf8
                ))
            case "/api/study/session/start":
                return Self.response(data: sessionData)
            default:
                XCTFail("Unexpected request: \(path)")
                throw URLError(.badServerResponse)
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

        let result = await store.recordReviewResult(
            card: reviewed,
            rating: .good,
            duration: nil
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(
            paths.values,
            [
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
        XCTAssertEqual(store.cards.map(\.id), [authoritative.id])
        XCTAssertFalse(store.cards.contains { $0.id == stale.id })
        XCTAssertEqual(store.sessionCompletedCardIDs, [reviewed.id])
    }

    @MainActor
    func testProgressionRevalidationPreservesEarlierPullFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000PE",
            expression: "失敗順序",
            variantGroupID: "progression-family",
            variantStatus: "available"
        )
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "/api/card-review-events/batch":
                return Self.response(statusCode: 204, data: Data())
            case "/api/sync/feed":
                throw URLError(.notConnectedToInternet)
            case "/api/study/session/start":
                return Self.response(
                    statusCode: 422,
                    data: Data(#"{"message":"Session revalidation failed"}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(path)")
                throw URLError(.badServerResponse)
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

        _ = await store.recordReviewResult(
            card: card,
            rating: .good,
            duration: nil
        )

        XCTAssertEqual(
            paths.values,
            [
                "/api/card-review-events/batch",
                "/api/sync/feed",
                "/api/study/session/start",
            ]
        )
        XCTAssertEqual(store.syncStatus, .offline)
    }

    @MainActor
    func testOfflineReviewedCardStaysOutOfQueueAfterRelaunch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000018",
            expression: "鳥"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let deliveryAttempts = LockedCounter()
        let client = makeClient { _ in
            _ = deliveryAttempts.next()
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .good, duration: .milliseconds(750))
        XCTAssertEqual(deliveryAttempts.current, 1)
        XCTAssertEqual(store.pendingOfflineReviewCount, 1)
        let relaunchedStore = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        XCTAssertEqual(relaunchedStore.pendingOfflineReviewCount, 1)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [card.id])
        XCTAssertEqual(relaunchedStore.libraryCards.map(\.id), [card.id])
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertFalse(record.isInActiveSession)
        let reviewMutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
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
            let mediaCache = MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            )
            let store = StudyStore(
                initialUserID: 1,
                api: client,
                context: container.mainContext,
                mediaCache: mediaCache,
                reviewEventOutboxFlushOverride: {
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
        let relaunchedMediaCache = MediaCache(
            initialUserID: 1,
            api: relaunchedClient,
            context: relaunchedContainer.mainContext
        )
        let relaunchedStore = StudyStore(
            initialUserID: 1,
            api: relaunchedClient,
            context: relaunchedContainer.mainContext,
            mediaCache: relaunchedMediaCache
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
        let container = try Persistence.makeContainer(inMemory: true)
        let clientID = "01J000000000000000000000RV"
        let canonicalID = clientID.lowercased()
        let staleCard = makeCard(
            id: clientID,
            expression: "古い識別子",
            queueState: "review"
        )
        let canonicalCard = makeCard(
            id: canonicalID,
            expression: "現在のローカル内容",
            queueState: "review"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: canonicalCard,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(canonicalCard)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(
            initialUserID: 1,
            api: client,
            context: container.mainContext
        )
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        let eventID = await store.recordReview(
            card: staleCard,
            rating: .again,
            duration: nil,
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNotNil(eventID)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.map(\.id), [canonicalID])
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, canonicalID)
        XCTAssertFalse(record.isInActiveSession)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.id, canonicalID)
        XCTAssertEqual(persisted.promptText, "現在のローカル内容")
        XCTAssertNotEqual(persisted.state, canonicalCard.state)
        let review = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>())
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
            cardBefore: staleCard
        )

        XCTAssertEqual(store.sessionFailureCount, 0)
        XCTAssertEqual(store.cards.map(\.id), [canonicalID])
        XCTAssertEqual(store.cards.first?.promptText, "現在のローカル内容")
    }

    @MainActor
    func testPendingReviewFiltersCaseCanonicalizedCardsFromEverySession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J0000000000000000000001R",
            expression: "保留"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(card)
            )
        )
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let mediaCache = MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        await store.recordReview(card: card, rating: .good, duration: nil)

        let serverCard = makeCard(
            id: card.id.lowercased(),
            expression: "保留"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 0,
                newCardsAvailableToday: 0
            ),
            cards: [serverCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(
            withJSONObject: ["data": sessionObject]
        )
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
        let relaunchedStore = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        try await relaunchedStore.refreshSession()
        XCTAssertTrue(relaunchedStore.cards.isEmpty)

        try await relaunchedStore.refreshLessons()
        XCTAssertTrue(relaunchedStore.cards.isEmpty)
    }

    @MainActor
    func testMasteryAnimationRemainsVisibleAfterTheReviewedCardAdvances() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
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
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 0,
                reviewCount: 1,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            if request.url?.path == "/api/study/session/start" {
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
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshSession()

        let recordedEventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(
            store.masteryAnimation?.fromLevel,
            StudyMasteryLevel.master.rawValue
        )
        XCTAssertEqual(
            store.masteryAnimation?.toLevel,
            StudyMasteryLevel.enlightened.rawValue
        )
        XCTAssertEqual(store.masteryAnimation?.card.id, card.id)
        XCTAssertEqual(store.masteryAnimation?.passed, true)

        try await store.undoReview(eventID: eventID, cardBefore: card)

        XCTAssertNil(store.masteryAnimation)

        let sameStageEventID = await store.recordReview(
            card: card,
            rating: .hard,
            duration: nil
        )

        XCTAssertEqual(store.masteryAnimation?.passed, true)
        XCTAssertEqual(
            store.masteryAnimation?.fromLevel,
            StudyMasteryLevel.master.rawValue
        )
        XCTAssertEqual(
            store.masteryAnimation?.toLevel,
            StudyMasteryLevel.master.rawValue
        )

        try await store.undoReview(
            eventID: try XCTUnwrap(sameStageEventID),
            cardBefore: card
        )

        _ = await store.recordReview(
            card: card,
            rating: .again,
            duration: nil
        )

        XCTAssertEqual(store.masteryAnimation?.passed, false)
        XCTAssertEqual(
            store.masteryAnimation?.fromLevel,
            StudyMasteryLevel.master.rawValue
        )
        XCTAssertEqual(
            store.masteryAnimation?.toLevel,
            StudyMasteryLevel.apprentice.rawValue
        )
    }
}
