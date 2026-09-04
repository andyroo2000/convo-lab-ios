import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

private struct RejectedReviewSeed {
    let localID: String
    let syncID: String?
    let expression: String
    let eventID: String
    let clientEventID: String
    let errorMessage: String
    var beforeDueAt: Date? = nil
    var afterDueAt: Date? = nil
    var beforeMastery: String? = nil
    var afterMastery: String? = nil
}

private struct RejectedReviewFixture {
    let container: ModelContainer
    let cardBefore: StudyCard
    let mutation: PendingMutation
}

extension StudyStoreTests {
    @MainActor
    func testRetryingRejectedReviewUsesOriginalPayloadAndClearsFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let offlineClient = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = makeRejectedReviewStore(container: container, client: offlineClient)
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
        let fixture = try makeRejectedReviewFixture(.init(
            localID: "01J000000000000000000000F6",
            syncID: nil,
            expression: "取り消す",
            eventID: "01J00000000000000000000E6",
            clientEventID: "discard-review",
            errorMessage: "HTTP 422: Invalid review",
            beforeDueAt: Date(timeIntervalSince1970: 1_700_000_000),
            afterDueAt: Date(timeIntervalSince1970: 1_800_000_000),
            beforeMastery: "learning",
            afterMastery: "mastered"
        ))
        let server = RejectedReviewBatchServer(
            responseData: try canonicalBatchData(cards: [fixture.cardBefore])
        )
        let client = makeClient { try server.response(for: $0) }
        let store = makeRejectedReviewStore(container: fixture.container, client: client)

        try await store.discardFailedStudyChange(id: fixture.mutation.id)

        _ = try assertCanonicalCardRestored(fixture, in: store)
    }

    @MainActor
    func testDiscardingRejectedReviewUsesServerIDAndRemovesStaleLocalCard() async throws {
        let localID = "8D748A0E-2EE9-49A9-8A32-7B9E4187C273"
        let serverID = "01J000000000000000000000F8"
        let fixture = try makeRejectedReviewFixture(.init(
            localID: localID,
            syncID: serverID,
            expression: "削除済み",
            eventID: "01J00000000000000000000E8",
            clientEventID: "discard-stale-review",
            errorMessage: "HTTP 422: The selected card id is invalid.",
            afterDueAt: Date(timeIntervalSince1970: 1_800_000_000),
            afterMastery: "mastered"
        ))
        let server = RejectedReviewBatchServer(responseData: Data(#"{"cards":[]}"#.utf8))
        let client = makeClient { try server.response(for: $0) }
        let store = makeRejectedReviewStore(container: fixture.container, client: client)

        XCTAssertEqual(store.failedStudyChanges.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.failedStudyChanges.first).isRetryable)

        try await store.retryFailedStudyChange(id: fixture.mutation.id)

        XCTAssertTrue(server.requestedCardIDs.isEmpty)
        XCTAssertEqual(store.failedStudyChanges.map(\.id), [fixture.mutation.id])

        try await store.discardFailedStudyChange(id: fixture.mutation.id)

        XCTAssertEqual(server.requestedCardIDs, [serverID.lowercased()])
        XCTAssertTrue(
            try fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )
        XCTAssertTrue(store.libraryCards.isEmpty)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
    }

    @MainActor
    func testDiscardingRejectedReviewUsesServerIDAndPreservesCanonicalCard() async throws {
        let localID = "14A15A14-E665-4021-907B-A0FC75C18AFB"
        let serverID = "01J000000000000000000000F9"
        let fixture = try makeRejectedReviewFixture(.init(
            localID: localID,
            syncID: serverID,
            expression: "残っている",
            eventID: "01J00000000000000000000E9",
            clientEventID: "discard-imported-review",
            errorMessage: "HTTP 422: Invalid review",
            beforeDueAt: Date(timeIntervalSince1970: 1_700_000_000),
            afterDueAt: Date(timeIntervalSince1970: 1_800_000_000),
            beforeMastery: "learning",
            afterMastery: "mastered"
        ))
        let server = RejectedReviewBatchServer(
            responseData: try canonicalBatchData(cards: [fixture.cardBefore])
        )
        let client = makeClient { try server.response(for: $0) }
        let store = makeRejectedReviewStore(container: fixture.container, client: client)

        try await store.discardFailedStudyChange(id: fixture.mutation.id)

        XCTAssertEqual(server.requestedCardIDs, [serverID.lowercased()])
        let restoredCard = try assertCanonicalCardRestored(fixture, in: store)
        XCTAssertEqual(restoredCard.id, localID)
        XCTAssertEqual(restoredCard.syncId, serverID)
    }

    @MainActor
    func testDiscardingRejectedReviewWithNoServerULIDSkipsCanonicalFetch() async throws {
        let localID = "8D748A0E-2EE9-49A9-8A32-7B9E4187C273"
        let fixture = try makeRejectedReviewFixture(.init(
            localID: localID,
            syncID: nil,
            expression: "孤立したカード",
            eventID: "01J00000000000000000000EA",
            clientEventID: "discard-invalid-ulid-review",
            errorMessage: "HTTP 422: The selected card id is invalid."
        ))

        let requests = LockedRequestPaths()
        let client = makeClient { request in
            requests.append(request.url?.path ?? "")
            throw URLError(.notConnectedToInternet)
        }
        let store = makeRejectedReviewStore(container: fixture.container, client: client)

        try await store.discardFailedStudyChange(id: fixture.mutation.id)

        XCTAssertFalse(requests.values.contains("/api/study/cards/batch"))
        XCTAssertTrue(
            try fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        XCTAssertTrue(
            try fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
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
        let store = makeRejectedReviewStore(container: container, client: client)

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
        let store = makeRejectedReviewStore(container: container, client: client)
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

        let server = QuarantinedReviewSyncServer(
            createdCardData: createdCardData,
            sessionData: sessionData
        )
        MockURLProtocol.handler = { server.response(for: $0) }

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

    @MainActor
    private func makeRejectedReviewFixture(
        _ seed: RejectedReviewSeed
    ) throws -> RejectedReviewFixture {
        let container = try Persistence.makeContainer(inMemory: true)
        let cardBefore = makeCard(
            id: seed.localID,
            syncId: seed.syncID,
            expression: seed.expression,
            dueAt: seed.beforeDueAt,
            masteryLevel: seed.beforeMastery
        )
        let cardAfter = makeCard(
            id: seed.localID,
            syncId: seed.syncID,
            expression: seed.expression,
            dueAt: seed.afterDueAt,
            masteryLevel: seed.afterMastery
        )
        let record = LocalCardRecord(
            card: cardAfter,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(cardAfter)
        )
        let event = ReviewBatchRequest.Event(
            id: seed.eventID,
            cardID: seed.localID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: nil,
            clientEventID: seed.clientEventID,
            deviceID: "device",
            clientCreatedAt: .now
        )
        let mutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: seed.localID,
            payload: try StorageCodec.encoder.encode(PendingReviewPayload(
                event: event,
                cardBefore: PendingReviewCardState(card: cardBefore)
            ))
        )
        mutation.lastError = seed.errorMessage
        container.mainContext.insert(record)
        container.mainContext.insert(mutation)
        try container.mainContext.save()
        return .init(container: container, cardBefore: cardBefore, mutation: mutation)
    }

    @MainActor
    private func makeRejectedReviewStore(
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
    private func canonicalBatchData(cards: [StudyCard]) throws -> Data {
        let objects = try cards.map {
            try JSONSerialization.jsonObject(with: StorageCodec.encoder.encode($0))
        }
        return try JSONSerialization.data(withJSONObject: ["cards": objects])
    }

    @MainActor
    private func assertCanonicalCardRestored(
        _ fixture: RejectedReviewFixture,
        in store: StudyStore
    ) throws -> StudyCard {
        XCTAssertTrue(
            try fixture.container.mainContext.fetch(FetchDescriptor<PendingMutation>()).isEmpty
        )
        let record = try XCTUnwrap(
            fixture.container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let restoredCard = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(restoredCard.state.dueAt, fixture.cardBefore.state.dueAt)
        XCTAssertEqual(restoredCard.masteryLevel, fixture.cardBefore.masteryLevel)
        XCTAssertEqual(store.libraryCards.first?.state.dueAt, fixture.cardBefore.state.dueAt)
        XCTAssertTrue(store.failedStudyChanges.isEmpty)
        return restoredCard
    }
}

private final class RejectedReviewBatchServer: @unchecked Sendable {
    private let requestedIDValues = LockedRequestPaths()
    private let responseData: Data

    init(responseData: Data) {
        self.responseData = responseData
    }

    var requestedCardIDs: [String] { requestedIDValues.values }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard request.url?.path == "/api/study/cards/batch" else {
            throw URLError(.notConnectedToInternet)
        }
        let body = try JSONSerialization.jsonObject(
            with: try requestBody(request)
        ) as? [String: Any]
        let ids = try XCTUnwrap(body?["ids"] as? [String])
        requestedIDValues.append(try XCTUnwrap(ids.first))
        return StudyStoreTests.response(data: responseData)
    }
}

private struct QuarantinedReviewSyncServer: @unchecked Sendable {
    let createdCardData: Data
    let sessionData: Data

    func response(for request: URLRequest) -> (HTTPURLResponse, Data) {
        switch request.url?.path {
        case "/api/card-review-events/batch":
            return response(
                for: request,
                statusCode: 422,
                data: Data(#"{"message":"Invalid review"}"#.utf8)
            )
        case "/api/study/cards":
            return response(for: request, statusCode: 201, data: createdCardData)
        default:
            return response(for: request, statusCode: 200, data: sessionData)
        }
    }

    private func response(
        for request: URLRequest,
        statusCode: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }
}
