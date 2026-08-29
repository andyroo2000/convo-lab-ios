import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class ReviewEventOutboxTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    @MainActor
    func testStageEnqueuePreservesWireAndIdempotencyMetadata() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let reviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(id: "card-local", failedAt: reviewedAt.addingTimeInterval(-60))
        let event = makeEvent(
            id: "event-1",
            cardID: "card-sync",
            rating: .hard,
            reviewedAt: reviewedAt,
            clientEventID: "client-event-1",
            deviceID: "device-1"
        )

        let mutation = try outbox.stageEnqueue(event: event, cardBefore: card)
        try container.mainContext.save()

        XCTAssertEqual(mutation.kind, "review")
        XCTAssertEqual(mutation.userID, 7)
        XCTAssertEqual(mutation.resourceID, "card-local")
        let payload = try StorageCodec.decoder.decode(
            PendingReviewPayload.self,
            from: mutation.payload
        )
        XCTAssertEqual(payload.event.id, "event-1")
        XCTAssertEqual(payload.event.cardID, "card-sync")
        XCTAssertEqual(payload.event.rating, .hard)
        XCTAssertEqual(payload.event.reviewedAt, reviewedAt)
        XCTAssertEqual(payload.event.durationMilliseconds, 750)
        XCTAssertEqual(payload.event.clientEventID, "client-event-1")
        XCTAssertEqual(payload.event.deviceID, "device-1")
        XCTAssertEqual(payload.event.clientCreatedAt, reviewedAt)
        XCTAssertEqual(payload.cardBefore.id, "card-local")
        XCTAssertEqual(payload.cardBefore.failedAt, card.state.failedAt)
    }

    @MainActor
    func testFlushUploadsMutationsInPersistentCreationOrderAndRemovesThem() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let uploadedEventIDs = LockedRequestPaths()
        let client = makeClient { request in
            let body = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            let events = try XCTUnwrap(body["events"] as? [[String: Any]])
            events.forEach { event in
                if let id = event["id"] as? String {
                    uploadedEventIDs.append(id)
                }
            }
            return Self.emptySuccess(for: request)
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let second = try outbox.stageEnqueue(
            event: makeEvent(id: "event-2", cardID: card.id, reviewedAt: base),
            cardBefore: card
        )
        let first = try outbox.stageEnqueue(
            event: makeEvent(id: "event-1", cardID: card.id, reviewedAt: base.addingTimeInterval(2)),
            cardBefore: card
        )
        let third = try outbox.stageEnqueue(
            event: makeEvent(id: "event-3", cardID: card.id, reviewedAt: base.addingTimeInterval(-2)),
            cardBefore: card
        )
        first.createdAt = base
        second.createdAt = base.addingTimeInterval(1)
        third.createdAt = base.addingTimeInterval(2)
        try container.mainContext.save()

        try await outbox.flush()

        XCTAssertEqual(uploadedEventIDs.values, ["event-1", "event-2", "event-3"])
        XCTAssertTrue(try pendingReviews(in: container).isEmpty)
    }

    @MainActor
    func testTransientFailurePreservesMutationForSuccessfulRetry() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let attempts = LockedCounter()
        let client = makeClient { request in
            if attempts.next() == 1 {
                throw URLError(.notConnectedToInternet)
            }
            return Self.emptySuccess(for: request)
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "event-1", cardID: card.id),
            cardBefore: card
        )
        try container.mainContext.save()

        do {
            try await outbox.flush()
            XCTFail("Expected the offline upload to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let pending = try XCTUnwrap(pendingReviews(in: container).first)
        XCTAssertEqual(pending.attemptCount, 1)
        XCTAssertNotNil(pending.lastAttemptAt)
        XCTAssertNil(pending.lastError)

        try await outbox.flush()

        XCTAssertEqual(attempts.current, 2)
        XCTAssertTrue(try pendingReviews(in: container).isEmpty)
    }

    @MainActor
    func testPermanentFailureQuarantinesMutationWithoutBlockingFutureFlushes() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 422,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Invalid review"}"#.utf8)
            )
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "event-1", cardID: card.id),
            cardBefore: card
        )
        try container.mainContext.save()

        do {
            try await outbox.flush()
            XCTFail("Expected the rejected review to be quarantined")
        } catch let error as QuarantinedReviewError {
            XCTAssertEqual(error.count, 1)
        }

        let pending = try XCTUnwrap(pendingReviews(in: container).first)
        XCTAssertEqual(pending.attemptCount, 1)
        XCTAssertEqual(pending.lastError, "HTTP 422: Invalid review")
        try await outbox.flush()
        XCTAssertEqual(try pendingReviews(in: container).count, 1)
    }

    @MainActor
    func testProgressionLockedReviewIsDiscardedWithoutQuarantine() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let attempts = LockedCounter()
        let client = makeClient { request in
            _ = attempts.next()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"message":"Card is locked by a learning progression."}"#.utf8)
            )
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        let record = LocalCardRecord(
            card: card,
            userID: 7,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = true
        container.mainContext.insert(record)
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "event-1", cardID: card.id),
            cardBefore: card
        )
        try container.mainContext.save()

        let result = try await outbox.flush()

        XCTAssertEqual(result.progressionLockedEventIDs, ["event-1"])
        XCTAssertEqual(attempts.current, 2)
        XCTAssertTrue(try pendingReviews(in: container).isEmpty)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testUnrelatedConflictRemainsQuarantined() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            Self.rejection(
                status: 409,
                message: "Review conflicts with a newer event.",
                for: request
            )
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        let record = LocalCardRecord(
            card: card,
            userID: 7,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        container.mainContext.insert(record)
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "event-1", cardID: card.id),
            cardBefore: card
        )
        try container.mainContext.save()

        do {
            try await outbox.flush()
            XCTFail("Expected the unrelated conflict to remain quarantined")
        } catch let error as QuarantinedReviewError {
            XCTAssertEqual(error.count, 1)
        }

        let pending = try XCTUnwrap(pendingReviews(in: container).first)
        XCTAssertEqual(
            pending.lastError,
            "HTTP 409: Review conflicts with a newer event."
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertNil(persisted.variantStatus)
    }

    @MainActor
    func testProgressionLockResultSurvivesMixedPermanentFailure() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { request in
            let eventIDs = try Self.eventIDs(in: request)
            if eventIDs.count > 1 {
                return Self.rejection(
                    status: 422,
                    message: "Batch contains an invalid review",
                    for: request
                )
            }
            if eventIDs == ["event-locked"] {
                return Self.rejection(
                    status: 409,
                    message: "Card is locked by a learning progression.",
                    for: request
                )
            }
            return Self.rejection(
                status: 422,
                message: "Invalid review",
                for: request
            )
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        outbox.activate(userID: 7)
        let lockedCard = makeCard(id: "locked-card")
        let invalidCard = makeCard(id: "invalid-card")
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "event-locked", cardID: lockedCard.id),
            cardBefore: lockedCard
        )
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "event-invalid", cardID: invalidCard.id),
            cardBefore: invalidCard
        )
        try container.mainContext.save()

        do {
            try await outbox.flush()
            XCTFail("Expected the invalid review to remain quarantined")
        } catch let failure as ReviewEventFlushFailure {
            XCTAssertEqual(failure.result.progressionLockedEventIDs, ["event-locked"])
            let quarantine = try XCTUnwrap(
                failure.underlyingError as? QuarantinedReviewError
            )
            XCTAssertEqual(quarantine.count, 1)
        }

        let pending = try XCTUnwrap(pendingReviews(in: container).first)
        XCTAssertEqual(pending.resourceID, invalidCard.id)
        XCTAssertEqual(pending.lastError, "HTTP 422: Invalid review")
    }

    @MainActor
    func testPreviouslyQuarantinedProgressionLockIsDiscardedWithoutNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = ReviewEventOutbox(
            api: makeClient { _ in
                XCTFail("Cleanup should not retry a known progression lock")
                throw URLError(.unknown)
            },
            context: container.mainContext
        )
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        let record = LocalCardRecord(
            card: card,
            userID: 7,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        container.mainContext.insert(record)
        let mutation = try outbox.stageEnqueue(
            event: makeEvent(id: "event-1", cardID: card.id),
            cardBefore: card
        )
        mutation.lastError = "HTTP 409: Card is locked by a learning progression."
        try container.mainContext.save()

        let result = try outbox.discardProgressionLockedFailures()

        XCTAssertEqual(result.progressionLockedEventIDs, ["event-1"])
        XCTAssertTrue(try pendingReviews(in: container).isEmpty)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.variantStatus, "locked")
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testPendingFailureStateUsesReviewTimeThenEventIDOrder() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let outbox = ReviewEventOutbox(
            api: makeClient { _ in throw URLError(.notConnectedToInternet) },
            context: container.mainContext
        )
        outbox.activate(userID: 7)
        let card = makeCard(id: "card-1")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let laterAgain = try outbox.stageEnqueue(
            event: makeEvent(
                id: "event-b",
                cardID: card.id,
                rating: .again,
                reviewedAt: base.addingTimeInterval(1)
            ),
            cardBefore: card
        )
        let earlierGood = try outbox.stageEnqueue(
            event: makeEvent(
                id: "event-a",
                cardID: card.id,
                rating: .good,
                reviewedAt: base
            ),
            cardBefore: card
        )
        laterAgain.createdAt = base
        earlierGood.createdAt = base.addingTimeInterval(1)
        try container.mainContext.save()

        let state = try outbox.pendingState()

        XCTAssertEqual(state.cardIDs, [card.id])
        XCTAssertEqual(state.newlyFailedCardIDs, [card.id])
        XCTAssertTrue(state.retainedFailedCardIDs.isEmpty)
        XCTAssertTrue(state.resolvedFailedCardIDs.isEmpty)
    }

    @MainActor
    func testAccountSwitchKeepsNewUsersFlushIndependentFromCancelledOldFlush() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (oldStarted, oldStartedContinuation) = AsyncStream<Void>.makeStream()
        let (newStarted, newStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseOld, releaseOldContinuation) = AsyncStream<Void>.makeStream()
        let (releaseNew, releaseNewContinuation) = AsyncStream<Void>.makeStream()
        let newRequestCount = LockedCounter()
        let client = makeDeferredClient { request, completion in
            let eventID = (try? Self.firstEventID(in: request)) ?? ""
            let release: AsyncStream<Void>
            if eventID == "old-event" {
                oldStartedContinuation.yield()
                release = releaseOld
            } else {
                _ = newRequestCount.next()
                newStartedContinuation.yield()
                release = releaseNew
            }
            Task {
                for await _ in release {
                    completion(.success(Self.emptySuccess(for: request)))
                    return
                }
            }
        }
        let outbox = ReviewEventOutbox(api: client, context: container.mainContext)
        let card = makeCard(id: "card-1")
        outbox.activate(userID: 1)
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "old-event", cardID: card.id),
            cardBefore: card
        )
        try container.mainContext.save()
        let oldFlush = Task { try await outbox.flush() }
        for await _ in oldStarted { break }

        outbox.activate(userID: 2)
        _ = try outbox.stageEnqueue(
            event: makeEvent(id: "new-event", cardID: card.id),
            cardBefore: card
        )
        try container.mainContext.save()
        let newFlush = Task { try await outbox.flush() }
        for await _ in newStarted { break }

        releaseOldContinuation.yield()
        _ = try? await oldFlush.value
        let joinedNewFlush = Task { try await outbox.flush() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(newRequestCount.current, 1)

        releaseNewContinuation.yield()
        _ = try await newFlush.value
        _ = try await joinedNewFlush.value

        XCTAssertFalse(try pendingReviews(in: container).contains { $0.userID == 2 })
        outbox.activate(userID: 2)
        XCTAssertTrue(try outbox.pendingState().cardIDs.isEmpty)
        outbox.activate(userID: 1)
        XCTAssertEqual(try outbox.pendingState().cardIDs, [card.id])
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    @MainActor
    private func pendingReviews(in container: ModelContainer) throws -> [PendingMutation] {
        try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "review" }
            )
        )
    }

    private static func emptySuccess(
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!,
            Data()
        )
    }

    private static func rejection(
        status: Int,
        message: String,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            try! JSONSerialization.data(withJSONObject: ["message": message])
        )
    }

    private static func eventIDs(in request: URLRequest) throws -> [String] {
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
        )
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        return events.compactMap { $0["id"] as? String }
    }

    private static func firstEventID(in request: URLRequest) throws -> String {
        try XCTUnwrap(eventIDs(in: request).first)
    }

    private func makeEvent(
        id: String,
        cardID: String,
        rating: ReviewRating = .good,
        reviewedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        clientEventID: String? = nil,
        deviceID: String = "device-1"
    ) -> ReviewBatchRequest.Event {
        ReviewBatchRequest.Event(
            id: id,
            cardID: cardID,
            rating: rating,
            reviewedAt: reviewedAt,
            durationMilliseconds: 750,
            clientEventID: clientEventID ?? "client-\(id)",
            deviceID: deviceID,
            clientCreatedAt: reviewedAt
        )
    }

    @MainActor
    private func makeCard(id: String, failedAt: Date? = nil) -> StudyCard {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        return StudyCard(
            id: id,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string("犬")]),
            answer: .object(["meaning": .string("dog")]),
            state: .init(
                dueAt: createdAt,
                introducedAt: createdAt,
                failedAt: failedAt,
                queueState: failedAt == nil ? "review" : "relearning",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
