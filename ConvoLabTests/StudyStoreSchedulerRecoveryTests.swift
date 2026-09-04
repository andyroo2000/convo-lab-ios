import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testSchedulerFailureDoesNotStageReviewOrMutateCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J000000000000000000000SF",
            expression: "安全",
            queueState: "review"
        )
        let originalPayload = try StorageCodec.encoder.encode(card)
        container.mainContext.insert(
            LocalCardRecord(
                card: card,
                userID: 1,
                queueIndex: 0,
                payload: originalPayload
            )
        )
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { request in
            _ = requests.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let failure = FSRSReviewScheduler.InvalidRatingStatesError(
            missingGrades: [4],
            unexpectedGrades: []
        )
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: 1,
                api: client,
                context: container.mainContext
            ),
            reviewProjection: { _, _, _ in throw failure }
        )

        let eventID = await store.recordReview(
            card: card,
            rating: .good,
            duration: nil
        )

        XCTAssertNil(eventID)
        XCTAssertEqual(store.syncStatus, .failed(failure.localizedDescription))
        XCTAssertEqual(requests.current, 0)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(try XCTUnwrap(records.first).payload, originalPayload)
        XCTAssertEqual(store.cards.first?.id, card.id)
        XCTAssertEqual(store.cards.first?.state, card.state)
    }

    @MainActor
    func testInvalidPersistedSchedulerTimestampDoesNotRequestAutomaticRetry() {
        let error = FSRSReviewScheduler.InvalidSchedulerTimestampError(field: "due")

        XCTAssertFalse(StudyStore.requiresAutomaticRetry(error))
    }

    @MainActor
    func testInvalidPersistedSchedulerTimestampRefetchesCanonicalCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (corrupted, canonical) = makeSchedulerRecoveryCards()
        container.mainContext.insert(
            LocalCardRecord(
                card: corrupted,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(corrupted)
            )
        )
        try container.mainContext.save()
        let responseData = try cardBatchResponseData(canonical)
        let requests = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            _ = requests.next()
            return Self.response(data: responseData)
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

        let eventID = await store.recordReview(
            card: corrupted,
            rating: .good,
            duration: nil
        )

        XCTAssertNil(eventID)
        XCTAssertEqual(requests.current, 1)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(store.cards.first?.state.scheduler, canonical.state.scheduler)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).state.scheduler,
            canonical.state.scheduler
        )
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    func testInvalidSchedulerRecoveryPreservesPendingLocalEdit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "pending-corrupted-card",
            expression: "未送信",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        let payload = try StorageCodec.encoder.encode(corrupted)
        let record = LocalCardRecord(
            card: corrupted,
            userID: 1,
            queueIndex: 0,
            payload: payload
        )
        let locallyUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        record.locallyUpdatedAt = locallyUpdatedAt
        container.mainContext.insert(record)
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate",
                userID: 1,
                resourceID: corrupted.id,
                payload: Data("pending-edit".utf8)
            )
        )
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { _ in
            _ = requests.next()
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        _ = await store.recordReview(card: corrupted, rating: .good, duration: nil)

        XCTAssertEqual(requests.current, 0)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(record.payload, payload)
        XCTAssertEqual(record.locallyUpdatedAt, locallyUpdatedAt)
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testInvalidSchedulerRecoveryPreservesEditStagedDuringRefetch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "in-flight-edit-corrupted-card",
            expression: "編集中",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        let canonical = makeCard(
            id: corrupted.id,
            expression: "サーバー版",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00.000Z"),
                "state": .number(2),
            ])
        )
        let payload = try StorageCodec.encoder.encode(corrupted)
        let record = LocalCardRecord(
            card: corrupted,
            userID: 1,
            queueIndex: 0,
            payload: payload
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
        let responseData = try cardBatchResponseData(canonical)
        let deferredRefetch = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            deferredRefetch.hold(completion)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        let reviewTask = Task { @MainActor in
            await store.recordReview(card: corrupted, rating: .good, duration: nil)
        }
        await deferredRefetch.waitUntilPending()
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate",
                userID: 1,
                resourceID: corrupted.id,
                payload: Data("in-flight-edit".utf8)
            )
        )
        try container.mainContext.save()
        deferredRefetch.succeed(with: Self.response(data: responseData))
        _ = await reviewTask.value

        XCTAssertEqual(record.payload, payload)
        XCTAssertFalse(record.isInActiveSession)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).count,
            1
        )
    }

    @MainActor
    func testInvalidSchedulerRecoveryPreservesPendingReviewState() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "pending-review-corrupted-card",
            expression: "復習待ち",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        let payload = try StorageCodec.encoder.encode(corrupted)
        let record = LocalCardRecord(
            card: corrupted,
            userID: 1,
            queueIndex: 0,
            payload: payload
        )
        container.mainContext.insert(record)
        let event = ReviewBatchRequest.Event(
            id: "pending-review-event",
            cardID: corrupted.id,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: "pending-review-client-event",
            deviceID: "device",
            clientCreatedAt: .now
        )
        container.mainContext.insert(
            PendingMutation(
                kind: "review",
                userID: 1,
                resourceID: corrupted.id,
                payload: try StorageCodec.encoder.encode(
                    PendingReviewPayload(
                        event: event,
                        cardBefore: PendingReviewCardState(card: corrupted)
                    )
                )
            )
        )
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { _ in
            _ = requests.next()
            throw URLError(.notConnectedToInternet)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        _ = await store.recordReview(card: corrupted, rating: .good, duration: nil)

        XCTAssertEqual(requests.current, 0)
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(record.payload, payload)
        XCTAssertFalse(record.isInActiveSession)
        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).count,
            1
        )
    }

    @MainActor
    func testInvalidSchedulerRecoveryDeletesServerConfirmedMissingCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let corrupted = makeCard(
            id: "deleted-corrupted-card",
            expression: "削除済み",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "state": .number(2),
            ])
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: corrupted,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(corrupted)
            )
        )
        try container.mainContext.save()
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"message":"Not found"}"#.utf8)
            )
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        _ = await store.recordReview(card: corrupted, rating: .good, duration: nil)

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.allCards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertEqual(store.syncStatus, .idle)
    }

    @MainActor
    func testReviewingFailedCardOptimisticallyUpdatesSessionCounts() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (failedCard, sessionData) = try makeFailedReviewFixture()
        let expectedSyncID = failedCard.syncId
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
            XCTAssertEqual(request.url?.path, "/api/card-review-events/batch")
            let body = try requestBody(request)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
            XCTAssertEqual(events.first?["card_id"] as? String, expectedSyncID)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"data":[]}"#.utf8)
            )
        }
        let store = StudyStore(initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )
        try await store.refreshSession()
        XCTAssertEqual(store.sessionCounts.failedDue, 3)

        await store.recordReview(card: failedCard, rating: .good, duration: nil)

        XCTAssertEqual(
            store.sessionCounts,
            StudySessionCounts(failedDue: 2, reviewRemaining: 0, newRemaining: 0)
        )
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
    }

    @MainActor
    private func makeSchedulerRecoveryCards() -> (corrupted: StudyCard, canonical: StudyCard) {
        let corrupted = makeCard(
            id: "corrupted-scheduler-card",
            expression: "修復",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00+14:01"),
                "last_review": .string("2027-01-14T08:00:00.000Z"),
                "state": .number(2),
            ])
        )
        let canonical = makeCard(
            id: corrupted.id,
            expression: "修復",
            scheduler: .object([
                "due": .string("2027-01-15T08:00:00.000Z"),
                "last_review": .string("2027-01-14T08:00:00.000Z"),
                "state": .number(2),
            ])
        )
        return (corrupted, canonical)
    }

    @MainActor
    private func cardBatchResponseData(_ card: StudyCard) throws -> Data {
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(card)
        )
        return try JSONSerialization.data(withJSONObject: ["cards": [object]])
    }

    @MainActor
    private func makeFailedReviewFixture() throws -> (card: StudyCard, responseData: Data) {
        let card = StudyCard(
            id: "98f42a62-8303-410e-ad4d-5a69c55911bb",
            syncId: "01J00000000000000000000010",
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("失敗")]),
            answer: .object(["meaning": .string("failure")]),
            state: .init(
                dueAt: .now,
                introducedAt: .now,
                failedAt: .now,
                queueState: "relearning",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 0,
                reviewCount: 0,
                newCardsPerDay: 20,
                newCardsAvailableToday: 0,
                failedCount: 3,
                failedDueCount: 3
            ),
            cards: [card]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        return (card, try JSONSerialization.data(withJSONObject: ["data": object]))
    }
}
