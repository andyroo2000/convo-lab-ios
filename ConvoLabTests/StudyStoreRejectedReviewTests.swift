import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testRetryingRejectedReviewUsesOriginalPayloadAndClearsFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1,
            api: offlineClient,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: offlineClient,
                context: container.mainContext
            )
        )
        let card = makeCard(
            id: "01J00000000000000000000F1",
            expression: "再試行"
        )
        let recordedEventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        let mutation = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        let originalPayload = mutation.payload
        mutation.lastError = "HTTP 422: Invalid review"
        try container.mainContext.save()
        store.reloadFailedStudyChanges()

        XCTAssertEqual(store.failedStudyChanges.map(\.kind), [.review])
        XCTAssertTrue(store.failedStudyChanges.first?.detail.contains("Good") == true)

        let uploadedEventIDs = LockedRequestPaths()
        MockURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(
                with: try requestBody(request)
            ) as? [String: Any]
            let events = try XCTUnwrap(body?["events"] as? [[String: Any]])
            uploadedEventIDs.append(try XCTUnwrap(events.first?["id"] as? String))
            return Self.response(statusCode: 204, data: Data())
        }

        try await store.retryFailedStudyChange(id: mutation.id)

        XCTAssertEqual(uploadedEventIDs.values, [eventID])
        let uploadedPayload = try XCTUnwrap(uploadedEventIDs.values.first)
        let original = try StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: originalPayload
        )
        XCTAssertEqual(uploadedPayload, original.event.id)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testDiscardingRejectedReviewRestoresCanonicalServerCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let cardBefore = makeCard(
            id: "01J000000000000000000000F6",
            expression: "取り消す",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            masteryLevel: "learning"
        )
        let cardAfter = makeCard(
            id: cardBefore.id,
            expression: "取り消す",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            masteryLevel: "mastered"
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E6",
            cardID: cardBefore.id,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: cardBefore.id,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: cardBefore)
                )
            )
        )
        mutation.lastError = "HTTP 422: Invalid review"
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        let cardData = try StorageCodec.encoder.encode(cardBefore)
        let cardObject = try JSONSerialization.jsonObject(with: cardData)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                return Self.response(data: canonicalData)
            }
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

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let restoredRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.state.dueAt, cardBefore.state.dueAt)
        XCTAssertEqual(restoredCard.masteryLevel, cardBefore.masteryLevel)
        XCTAssertEqual(store.libraryCards.first?.state.dueAt, cardBefore.state.dueAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewUsesServerIDAndRemovesStaleLocalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localID = "8D748A0E-2EE9-49A9-8A32-7B9E4187C273"
        let serverID = "01J000000000000000000000F8"
        let cardBefore = makeCard(
            id: localID,
            syncId: serverID,
            expression: "削除済み"
        )
        let cardAfter = makeCard(
            id: localID,
            syncId: serverID,
            expression: "削除済み",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            masteryLevel: "mastered"
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E8",
            cardID: localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-stale-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: localID,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: cardBefore)
                )
            )
        )
        mutation.lastError = "HTTP 422: The selected card id is invalid."
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()

        let requestedCardIDs = LockedRequestPaths()
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                let ids = try XCTUnwrap(body?["ids"] as? [String])
                requestedCardIDs.append(try XCTUnwrap(ids.first))
                return Self.response(data: Data(#"{"cards":[]}"#.utf8))
            }
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

        XCTAssertEqual(store.failedStudyChanges.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.failedStudyChanges.first).isRetryable)

        try await store.retryFailedStudyChange(id: mutation.id)

        XCTAssertTrue(requestedCardIDs.values.isEmpty)
        XCTAssertEqual(store.failedStudyChanges.map(\.id), [mutation.id])

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertEqual(requestedCardIDs.values, [serverID.lowercased()])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewUsesServerIDAndPreservesCanonicalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localID = "14A15A14-E665-4021-907B-A0FC75C18AFB"
        let serverID = "01J000000000000000000000F9"
        let cardBefore = makeCard(
            id: localID,
            syncId: serverID,
            expression: "残っている",
            dueAt: Date(timeIntervalSince1970: 1_700_000_000),
            masteryLevel: "learning"
        )
        let cardAfter = makeCard(
            id: localID,
            syncId: serverID,
            expression: "残っている",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            masteryLevel: "mastered"
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E9",
            cardID: localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-imported-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: localID,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: cardBefore)
                )
            )
        )
        mutation.lastError = "HTTP 422: Invalid review"
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()

        let requestedCardIDs = LockedRequestPaths()
        let cardData = try StorageCodec.encoder.encode(cardBefore)
        let cardObject = try JSONSerialization.jsonObject(with: cardData)
        let canonicalData = try JSONSerialization.data(
            withJSONObject: ["cards": [cardObject]]
        )
        let client = makeClient { request in
            if request.url?.path == "/api/study/cards/batch" {
                let body = try JSONSerialization.jsonObject(
                    with: try requestBody(request)
                ) as? [String: Any]
                let ids = try XCTUnwrap(body?["ids"] as? [String])
                requestedCardIDs.append(try XCTUnwrap(ids.first))
                return Self.response(data: canonicalData)
            }
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

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertEqual(requestedCardIDs.values, [serverID.lowercased()])
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let restoredRecord = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let restoredCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: restoredRecord.payload
        )
        XCTAssertEqual(restoredCard.id, localID)
        XCTAssertEqual(restoredCard.syncId, serverID)
        XCTAssertEqual(restoredCard.state.dueAt, cardBefore.state.dueAt)
        XCTAssertEqual(restoredCard.masteryLevel, cardBefore.masteryLevel)
        XCTAssertEqual(store.libraryCards.first?.state.dueAt, cardBefore.state.dueAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewWithNoServerULIDSkipsCanonicalFetch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localID = "8D748A0E-2EE9-49A9-8A32-7B9E4187C273"
        let card = makeCard(id: localID, expression: "孤立したカード")
        let record = LocalCardRecord(
            card: card,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000EA",
            cardID: localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "discard-invalid-ulid-review",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: localID,
            payload: try StorageCodec.encoder.encode(
                PendingReviewPayload(
                    event: event,
                    cardBefore: PendingReviewCardState(card: card)
                )
            )
        )
        mutation.lastError = "HTTP 422: The selected card id is invalid."
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()

        let requests = LockedRequestPaths()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "")
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

        try await store.discardFailedStudyChange(id: mutation.id)

        XCTAssertFalse(requests.values.contains("/api/study/cards/batch"))
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testOfflineRetryKeepsRejectedReviewPayloadPending() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let card = makeCard(
            id: "01J00000000000000000000F2",
            expression: "保留"
        )
        let event = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E1",
            cardID: card.id,
            rating: .hard,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "client-event",
            deviceID: "device",
            clientCreatedAt: .now
        )
        let payload = try StorageCodec.encoder.encode(
            PendingReviewPayload(
                event: event,
                cardBefore: PendingReviewCardState(card: card)
            )
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: card.id,
            payload: payload
        )
        mutation.lastError = "HTTP 422: Invalid review"
        container.mainContext.insert(mutation)
        try container.mainContext.save()
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

        do {
            try await store.retryFailedStudyChange(id: mutation.id)
            XCTFail("Expected retry to remain pending while offline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        let retained = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<PendingMutation>()).first
        )
        XCTAssertEqual(retained.id, mutation.id)
        XCTAssertEqual(retained.payload, payload)
        XCTAssertNil(retained.lastError)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        XCTAssertEqual(store.pendingOfflineReviewCount, 1)
    }

    @MainActor
    func testQuarantinedReviewDoesNotBlockCardSyncOrSessionRefresh() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        let rejectedReviewCard = makeCard(
            id: "01J00000000000000000000005",
            expression: "失敗"
        )
        await store.recordReview(card: rejectedReviewCard, rating: .good, duration: nil)
        try await store.createCard(expression: "同期", reading: "どうき", meaning: "sync")
        let createdCard = try XCTUnwrap(store.libraryCards.last)
        let createdCardData = try StorageCodec.encoder.encode(createdCard)
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 1,
                newCount: 1,
                reviewCount: 1,
                newCardsPerDay: 10,
                newCardsAvailableToday: 1
            ),
            cards: [rejectedReviewCard, createdCard]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let sessionData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])

        MockURLProtocol.handler = { request in
            let path = request.url?.path
            if path == "/api/card-review-events/batch" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 422,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Invalid review"}"#.utf8)
                )
            }
            if path == "/api/study/cards" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    createdCardData
                )
            }
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

        await store.synchronize()

        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(pending.filter { $0.kind == "review" }.count, 1)
        XCTAssertTrue(pending.filter { $0.kind.hasPrefix("card") }.isEmpty)
        XCTAssertEqual(store.overview?.newCount, 1)
        XCTAssertEqual(Set(store.cards.map(\.id)), [rejectedReviewCard.id, createdCard.id])
        XCTAssertNil(
            store.lastSyncAt,
            "A quarantined mutation is a partial sync, even though its session data is usable."
        )
    }
}
