import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    private struct OfflineProjectionRequest {
        let action: StudyCardActionName
        let mode: StudyCardSetDueMode?
        let dueAt: Date?
        let timeZone: TimeZone
        let now: Date
    }

    @MainActor
    func testSuspendCardPostsActionAndRemovesItFromTheActiveSession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let card = makeCard(
            id: "01J00000000000000000000S1",
            expression: "Suspend me",
            queueState: "review",
            dueAt: dueAt
        )
        try insertLocalCard(card, userID: 1, container: container)
        let suspended = replacingSchedule(card, queueState: "suspended", dueAt: dueAt)
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: suspended,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let cardID = card.id
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/\(cardID)/actions")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(payload["action"] as? String, "suspend")
            XCTAssertNil(payload["mode"])
            XCTAssertNil(payload["dueAt"])
            XCTAssertNil(payload["timeZone"])
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let updated = try await store.performCardAction(.suspend, on: card)

        XCTAssertEqual(updated.state.queueState, "suspended")
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.libraryCards.first?.state.queueState, "suspended")
        XCTAssertEqual(store.overview?.dueCount, 0)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testForgetCardResetsItToNewAndPersistsTheServerSchedule() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000F1",
            expression: "Forget me",
            queueState: "review",
            dueAt: .now,
            scheduler: .object(["state": .number(2), "reps": .number(12)])
        )
        try insertLocalCard(card, userID: 1, container: container)
        let forgotten = replacingSchedule(
            card,
            queueState: "new",
            dueAt: nil,
            scheduler: .object(["state": .number(0), "reps": .number(0)])
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: forgotten,
            overview: actionOverview(dueCount: 0, newCount: 1, reviewCount: 0)
        ))
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(payload["action"] as? String, "forget")
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let updated = try await store.performCardAction(.forget, on: card)

        XCTAssertEqual(updated.state.queueState, "new")
        XCTAssertNil(updated.state.dueAt)
        XCTAssertEqual(updated.state.scheduler?["reps"], .number(0))
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.overview?.newCount, 1)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.state, updated.state)
    }

    @MainActor
    func testOfflineForgetProjectionUsesServerFreshSchedulerDefaults() throws {
        let now = try XCTUnwrap(ISO8601Milliseconds.date(from: "2026-03-08T04:00:00.000Z"))
        let card = makeCard(
            id: "01J00000000000000000OF01",
            expression: "Forget offline",
            queueState: "review",
            dueAt: now,
            scheduler: .object([
                "state": .number(2),
                "stability": .number(30),
                "difficulty": .number(7),
            ])
        )

        let projection = try prepareOfflineProjection(
            for: card,
            request: OfflineProjectionRequest(
                action: .forget,
                mode: nil,
                dueAt: nil,
                timeZone: .gmt,
                now: now
            )
        )

        XCTAssertEqual(projection.card.state.scheduler?["stability"], .number(0.1))
        XCTAssertEqual(projection.card.state.scheduler?["difficulty"], .number(5))
    }

    @MainActor
    func testOfflineSetDueUsesElapsedTimeAcrossSpringDSTBoundary() throws {
        // 11 PM EST to 9 AM EDT crosses a local date boundary but is only nine hours.
        try assertOfflineSetDueAcrossDSTBoundary(
            now: "2026-03-08T04:00:00.000Z",
            dueAt: "2026-03-08T13:00:00.000Z",
            id: "01J00000000000000000SD01",
            expression: "Spring forward"
        )
    }

    @MainActor
    func testOfflineSetDueUsesElapsedTimeAcrossFallDSTBoundary() throws {
        // 11 PM EDT to 9 AM EST crosses a local date boundary but is only eleven hours.
        try assertOfflineSetDueAcrossDSTBoundary(
            now: "2026-11-01T03:00:00.000Z",
            dueAt: "2026-11-01T14:00:00.000Z",
            id: "01J00000000000000000FD01",
            expression: "Fall back"
        )
    }

    @MainActor
    func testSetDueSendsTomorrowTimezoneAndCustomDatePayloads() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000D1",
            expression: "Set me due",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let futureDueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rescheduled = replacingSchedule(card, queueState: "review", dueAt: futureDueAt)
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: rescheduled,
            overview: actionOverview(dueCount: 0, reviewCount: 1)
        ))
        let bodies = LockedRequestBodies()
        let client = makeClient { request in
            bodies.append(try requestBody(request))
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        _ = try await store.performCardAction(
            .setDue,
            on: card,
            mode: .tomorrow,
            timeZone: newYork
        )
        _ = try await store.performCardAction(
            .setDue,
            on: rescheduled,
            mode: .customDate,
            dueAt: futureDueAt,
            timeZone: newYork
        )

        XCTAssertEqual(bodies.values.count, 2)
        let tomorrow = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies.values[0]) as? [String: Any]
        )
        XCTAssertEqual(tomorrow["action"] as? String, "set_due")
        XCTAssertEqual(tomorrow["mode"] as? String, "custom_date")
        XCTAssertNil(tomorrow["timeZone"])
        let tomorrowDueAt = try XCTUnwrap(tomorrow["dueAt"] as? String)
        let parsedTomorrowDueAt = try XCTUnwrap(ISO8601Milliseconds.date(from: tomorrowDueAt))
        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = newYork
        XCTAssertEqual(newYorkCalendar.component(.hour, from: parsedTomorrowDueAt), 9)
        XCTAssertEqual(
            newYorkCalendar.dateComponents(
                [.day],
                from: newYorkCalendar.startOfDay(for: .now),
                to: newYorkCalendar.startOfDay(for: parsedTomorrowDueAt)
            ).day,
            1
        )
        let custom = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies.values[1]) as? [String: Any]
        )
        XCTAssertEqual(custom["mode"] as? String, "custom_date")
        XCTAssertNotNil(custom["dueAt"] as? String)
        XCTAssertNil(custom["timeZone"])
        XCTAssertTrue(store.cards.isEmpty)
    }

    @MainActor
    func testSetDueNowKeepsAnEligibleCardInTheActiveSession() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000N1",
            expression: "Due now",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let dueNow = replacingSchedule(
            card,
            queueState: "review",
            dueAt: Date(timeIntervalSinceNow: -1)
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: dueNow,
            overview: actionOverview(dueCount: 1, reviewCount: 1)
        ))
        let client = makeClient { request in
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            )
            XCTAssertEqual(payload["action"] as? String, "set_due")
            XCTAssertEqual(payload["mode"] as? String, "custom_date")
            XCTAssertNotNil(payload["dueAt"] as? String)
            XCTAssertNil(payload["timeZone"])
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let updated = try await store.performCardAction(.setDue, on: card, mode: .now)

        XCTAssertEqual(store.cards, [updated])
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertTrue(record.isInActiveSession)
    }

    @MainActor
    func testCardActionPreservesAnEditQueuedWhileTheRequestIsInFlight() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000P1",
            expression: "Original prompt",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let serverCard = makeCard(
            id: card.id,
            expression: "Stale server prompt",
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let deferredAction = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            if request.url?.path.hasSuffix("/actions") == true {
                deferredAction.hold(completion)
            } else if request.httpMethod == "PATCH" {
                completion(.failure(URLError(.notConnectedToInternet)))
            } else {
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = makeStore(container: container, client: client, userID: 1)
        let actionTask = Task {
            try await store.performCardAction(.suspend, on: card)
        }
        await deferredAction.waitUntilPending()

        try await store.updateCard(
            card,
            prompt: "Local pending edit",
            reading: "",
            answer: "Local answer"
        )
        deferredAction.succeed(with: Self.response(data: responseData))
        let updated = try await actionTask.value

        XCTAssertEqual(updated.promptText, "Local pending edit")
        XCTAssertEqual(updated.answerText, "Local answer")
        XCTAssertEqual(updated.state.queueState, "suspended")
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertNotNil(record.locallyUpdatedAt)
        let persisted = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(persisted.promptText, "Local pending edit")
        XCTAssertEqual(persisted.state.queueState, "suspended")
        let pendingUpdates = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "cardUpdate" }
            )
        )
        XCTAssertEqual(pendingUpdates.count, 1)
    }

    @MainActor
    func testCardActionPersistsOfflineAndReplaysAfterStoreRestart() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q1",
            expression: "Queue offline",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let offlineClient = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let firstStore = makeStore(container: container, client: offlineClient, userID: 1)

        let optimistic = try await firstStore.performCardAction(.suspend, on: card)

        XCTAssertEqual(optimistic.state.queueState, "suspended")
        XCTAssertTrue(firstStore.cards.isEmpty)
        var pending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "cardAction" }
            )
        )
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attemptCount, 1)
        firstStore.deactivate()

        let serverCard = replacingSchedule(
            card,
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let paths = LockedRequestPaths()
        let onlineClient = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path.hasSuffix("/actions") {
                return Self.response(data: responseData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let restoredStore = makeStore(container: container, client: onlineClient, userID: 1)
        XCTAssertEqual(restoredStore.libraryCards.first?.state.queueState, "suspended")

        await restoredStore.synchronize()

        XCTAssertTrue(paths.values.contains { $0.hasSuffix("/actions") })
        pending = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.kind == "cardAction" }
            )
        )
        XCTAssertTrue(pending.isEmpty)
        let record = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first
        )
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).state.queueState,
            "suspended"
        )
    }

    @MainActor
    func testCardActionLostResponseRetriesTheSameAbsoluteDueRequest() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q2",
            expression: "Retry exactly",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let serverCard = replacingSchedule(card, queueState: "review", dueAt: dueAt)
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 1)
        ))
        let attempts = LockedCounter()
        let bodies = LockedRequestBodies()
        let client = makeClient { request in
            guard request.url?.path.hasSuffix("/actions") == true else {
                throw URLError(.notConnectedToInternet)
            }
            bodies.append(try requestBody(request))
            if attempts.next() == 1 {
                throw URLError(.timedOut)
            }
            return Self.response(data: responseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        _ = try await store.performCardAction(
            .setDue,
            on: card,
            mode: .customDate,
            dueAt: dueAt
        )
        await store.synchronize()

        XCTAssertEqual(bodies.values.count, 2)
        XCTAssertEqual(
            try StorageCodec.decoder.decode(
                StudyCardActionRequest.self,
                from: bodies.values[0]
            ),
            try StorageCodec.decoder.decode(
                StudyCardActionRequest.self,
                from: bodies.values[1]
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodies.values[0]) as? [String: Any]
        )
        XCTAssertEqual(payload["mode"] as? String, "custom_date")
        XCTAssertEqual(
            ISO8601Milliseconds.date(from: try XCTUnwrap(payload["dueAt"] as? String)),
            dueAt
        )
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "cardAction" }
                )
            ),
            0
        )
    }

    @MainActor
    func testPendingReviewDrainsBeforeLaterQueuedCardAction() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q3",
            expression: "Keep order",
            queueState: "review",
            dueAt: .now
        )
        try insertLocalCard(card, userID: 1, container: container)
        let reviewEvent = ReviewBatchRequest.Event(
            id: "01J00000000000000000000E1",
            cardID: card.reviewCardID,
            rating: .good,
            reviewedAt: .now,
            durationMilliseconds: 900,
            clientEventID: "01J00000000000000000000E1",
            deviceID: "test-device",
            clientCreatedAt: .now
        )
        container.mainContext.insert(PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: card.id,
            payload: try StorageCodec.encoder.encode(PendingReviewPayload(
                event: reviewEvent,
                cardBefore: PendingReviewCardState(card: card)
            ))
        ))
        try container.mainContext.save()
        let serverCard = replacingSchedule(
            card,
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let responseData = try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: serverCard,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        ))
        let online = LockedCounter()
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if online.current == 0 {
                throw URLError(.notConnectedToInternet)
            }
            if path == "/api/card-review-events/batch" {
                return Self.response(data: Data())
            }
            if path.hasSuffix("/actions") {
                return Self.response(data: responseData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        _ = try await store.performCardAction(.suspend, on: card)
        XCTAssertFalse(paths.values.contains { $0.hasSuffix("/actions") })
        _ = online.next()
        await store.synchronize()

        let deliveredWrites = paths.values.filter {
            $0 == "/api/card-review-events/batch" || $0.hasSuffix("/actions")
        }
        XCTAssertEqual(Array(deliveredWrites.suffix(2)), [
            "/api/card-review-events/batch",
            "/api/study/cards/\(card.reviewCardID)/actions",
        ])
    }

    @MainActor
    func testReviewAfterOfflineCardActionIsQueuedAndDeliveredAfterTheAction() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q6",
            expression: "Grade after action",
            queueState: "suspended",
            dueAt: nil,
            scheduler: .object(["state": .number(2)])
        )
        try insertLocalCard(card, userID: 1, container: container)
        let unsuspended = replacingSchedule(
            card,
            queueState: "review",
            dueAt: .now
        )
        let actionResponseData = try StorageCodec.encoder.encode(
            StudyCardActionResponse(
                card: unsuspended,
                overview: actionOverview(dueCount: 1, reviewCount: 1)
            )
        )
        let online = LockedCounter()
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            guard online.current > 0 else {
                throw URLError(.notConnectedToInternet)
            }
            if path.hasSuffix("/actions") {
                return Self.response(data: actionResponseData)
            }
            if path == "/api/card-review-events/batch" {
                return Self.response(data: Data())
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let optimisticAction = try await store.performCardAction(.unsuspend, on: card)
        let eventID = await store.recordReview(
            card: optimisticAction,
            rating: .good,
            duration: .seconds(1)
        )

        XCTAssertNotNil(eventID)
        XCTAssertTrue(store.cards.isEmpty)
        try assertQueuedCardActionThenReview(in: container)

        _ = online.next()
        await store.synchronize()

        let deliveredWrites = paths.values.filter {
            $0.hasSuffix("/actions") || $0 == "/api/card-review-events/batch"
        }
        XCTAssertEqual(Array(deliveredWrites.suffix(2)), [
            "/api/study/cards/\(card.reviewCardID)/actions",
            "/api/card-review-events/batch",
        ])
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate {
                        $0.kind == "cardAction" || $0.kind == "review"
                    }
                )
            ),
            0
        )
    }

    @MainActor
    func testEarlierEditAcknowledgementPreservesLaterQueuedActionProjection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q4",
            expression: "Original",
            queueState: "review",
            dueAt: .now,
            introductionCohortID: "cohort-1",
            selectionPolicy: "priority",
            priorityUntil: Date(timeIntervalSince1970: 600),
            introductionAvailableAt: Date(timeIntervalSince1970: 700)
        )
        try insertLocalCard(card, userID: 1, container: container)
        let editedServerCard = makeCard(
            id: card.id,
            expression: "Edited",
            queueState: "review",
            dueAt: card.state.dueAt,
            introductionCohortID: card.introductionCohortId,
            selectionPolicy: card.selectionPolicy,
            priorityUntil: card.priorityUntil,
            introductionAvailableAt: card.introductionAvailableAt
        )
        let editedServerData = try StorageCodec.encoder.encode(editedServerCard)
        let phase = LockedCounter()
        let client = makeClient { request in
            guard phase.current > 0 else {
                throw URLError(.notConnectedToInternet)
            }
            if request.httpMethod == "PATCH" {
                return Self.response(data: editedServerData)
            }
            throw URLError(.notConnectedToInternet)
        }
        let store = makeStore(container: container, client: client, userID: 1)
        try await store.updateCard(
            card,
            prompt: "Edited",
            reading: "",
            answer: "meaning"
        )
        _ = phase.next()

        let optimistic = try await store.performCardAction(.suspend, on: card)

        XCTAssertEqual(optimistic.promptText, "Edited")
        XCTAssertEqual(optimistic.state.queueState, "suspended")
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.state.queueState, "suspended")
        XCTAssertEqual(persisted.introductionCohortId, "cohort-1")
        XCTAssertEqual(persisted.selectionPolicy, "priority")
        XCTAssertEqual(persisted.priorityUntil, Date(timeIntervalSince1970: 600))
        XCTAssertEqual(
            persisted.introductionAvailableAt,
            Date(timeIntervalSince1970: 700)
        )
        let pendingKinds = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>()
        ).map(\.kind)
        XCTAssertEqual(pendingKinds, ["cardAction"])
    }

    @MainActor
    func testMultipleOfflineCardActionsReplayInOrderAndKeepNewestProjection() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(
            id: "01J00000000000000000000Q5",
            expression: "Ordered actions",
            queueState: "review",
            dueAt: .now,
            introductionCohortID: "cohort-1",
            selectionPolicy: "priority",
            priorityUntil: Date(timeIntervalSince1970: 600),
            introductionAvailableAt: Date(timeIntervalSince1970: 700)
        )
        try insertLocalCard(card, userID: 1, container: container)
        let futureDueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let suspended = replacingSchedule(
            card,
            queueState: "suspended",
            dueAt: card.state.dueAt
        )
        let rescheduled = replacingSchedule(
            card,
            queueState: "review",
            dueAt: futureDueAt
        )
        let suspendedResponseData = try actionResponseData(
            card: suspended,
            overview: actionOverview(dueCount: 0, reviewCount: 0)
        )
        let rescheduledResponseData = try actionResponseData(
            card: rescheduled,
            overview: actionOverview(dueCount: 0, reviewCount: 1)
        )
        let online = LockedCounter()
        let deliveredBodies = LockedRequestBodies()
        let client = makeClient { request in
            guard request.url?.path.hasSuffix("/actions") == true,
                  online.current > 0
            else {
                throw URLError(.notConnectedToInternet)
            }
            let body = try requestBody(request)
            deliveredBodies.append(body)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            return Self.response(data: payload["action"] as? String == "suspend"
                ? suspendedResponseData
                : rescheduledResponseData)
        }
        let store = makeStore(container: container, client: client, userID: 1)

        let firstProjection = try await store.performCardAction(.suspend, on: card)
        let latestProjection = try await store.performCardAction(
            .setDue,
            on: firstProjection,
            mode: .customDate,
            dueAt: futureDueAt
        )
        assertCohortMetadata(on: firstProjection)
        XCTAssertEqual(latestProjection.state.queueState, "review")
        XCTAssertEqual(latestProjection.state.dueAt, futureDueAt)
        _ = online.next()

        await store.synchronize()

        try assertDeliveredActions(in: deliveredBodies)
        let persisted = try persistedCard(in: container)
        XCTAssertEqual(persisted.state.dueAt, futureDueAt)
        assertCohortMetadata(on: persisted)
        try assertNoPendingCardActions(in: container)
    }

    @MainActor
    func testSetDueCustomDateUsesNineAMInTheSelectedCalendar() throws {
        let newYork = try newYorkTimeZone()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let selected = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 16, minute: 45)
        ))

        let dueAt = StudySetDueView.localNineAM(on: selected, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: dueAt)

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 27)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    @MainActor
    private func insertLocalCard(
        _ card: StudyCard,
        userID: Int,
        container: ModelContainer
    ) throws {
        container.mainContext.insert(LocalCardRecord(
            card: card,
            userID: userID,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        ))
        try container.mainContext.save()
    }

    @MainActor
    private func assertOfflineSetDueAcrossDSTBoundary(
        now nowString: String,
        dueAt dueAtString: String,
        id: String,
        expression: String
    ) throws {
        let newYork = try newYorkTimeZone()
        let now = try XCTUnwrap(ISO8601Milliseconds.date(from: nowString))
        let dueAt = try XCTUnwrap(ISO8601Milliseconds.date(from: dueAtString))
        let card = makeCard(
            id: id,
            expression: expression,
            queueState: "review",
            dueAt: now
        )
        let projection = try prepareOfflineProjection(
            for: card,
            request: OfflineProjectionRequest(
                action: .setDue,
                mode: .customDate,
                dueAt: dueAt,
                timeZone: newYork,
                now: now
            )
        )
        XCTAssertEqual(projection.card.state.scheduler?["scheduled_days"], .number(0))
    }

    @MainActor
    private func assertQueuedCardActionThenReview(in container: ModelContainer) throws {
        let queuedKinds = try container.mainContext.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate {
                    $0.kind == "cardAction" || $0.kind == "review"
                },
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
            )
        ).map(\.kind)
        XCTAssertEqual(queuedKinds, ["cardAction", "review"])
    }

    @MainActor
    private func assertCohortMetadata(on card: StudyCard) {
        XCTAssertEqual(card.introductionCohortId, "cohort-1")
        XCTAssertEqual(card.selectionPolicy, "priority")
        XCTAssertEqual(card.priorityUntil, Date(timeIntervalSince1970: 600))
        XCTAssertEqual(card.introductionAvailableAt, Date(timeIntervalSince1970: 700))
    }

    private func newYorkTimeZone() throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    }

    @MainActor
    private func assertDeliveredActions(in bodies: LockedRequestBodies) throws {
        let actions = try bodies.values.map {
            try StorageCodec.decoder.decode(StudyCardActionRequest.self, from: $0).action
        }
        XCTAssertEqual(actions, [.suspend, .setDue])
    }

    @MainActor
    private func prepareOfflineProjection(
        for card: StudyCard,
        request: OfflineProjectionRequest
    ) throws -> (request: StudyCardActionRequest, card: StudyCard) {
        try StudyCardActionProjection.prepare(
            action: request.action,
            card: card,
            mode: request.mode,
            dueAt: request.dueAt,
            timeZone: request.timeZone,
            now: request.now
        )
    }

    @MainActor
    private func actionResponseData(
        card: StudyCard,
        overview: StudyOverview
    ) throws -> Data {
        try StorageCodec.encoder.encode(StudyCardActionResponse(
            card: card,
            overview: overview
        ))
    }

    @MainActor
    private func assertNoPendingCardActions(in container: ModelContainer) throws {
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<PendingMutation>(
                    predicate: #Predicate { $0.kind == "cardAction" }
                )
            ),
            0
        )
    }

    @MainActor
    private func makeStore(
        container: ModelContainer,
        client: APIClient,
        userID: Int
    ) -> StudyStore {
        StudyStore(
            initialUserID: userID,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(
                initialUserID: userID,
                api: client,
                context: container.mainContext
            )
        )
    }

    @MainActor
    private func actionOverview(
        dueCount: Int,
        newCount: Int = 0,
        reviewCount: Int
    ) -> StudyOverview {
        StudyOverview(
            dueCount: dueCount,
            newCount: newCount,
            reviewCount: reviewCount,
            totalCards: 1,
            newCardsPerDay: 20,
            newCardsAvailableToday: newCount
        )
    }

    @MainActor
    private func replacingSchedule(
        _ card: StudyCard,
        queueState: String,
        dueAt: Date?,
        scheduler: JSONValue? = nil
    ) -> StudyCard {
        StudyCard(
            id: card.id,
            syncId: card.syncId,
            noteId: card.noteId,
            cardType: card.cardType,
            prompt: card.prompt,
            answer: card.answer,
            state: .init(
                dueAt: dueAt,
                introducedAt: card.state.introducedAt,
                failedAt: queueState == "new" ? nil : card.state.failedAt,
                queueState: queueState,
                scheduler: scheduler ?? card.state.scheduler,
                source: card.state.source
            ),
            answerAudioSource: card.answerAudioSource,
            masteryLevel: card.masteryLevel,
            variantGroupId: card.variantGroupId,
            variantStatus: card.variantStatus,
            introductionCohortId: card.introductionCohortId,
            selectionPolicy: card.selectionPolicy,
            priorityUntil: card.priorityUntil,
            introductionAvailableAt: card.introductionAvailableAt,
            createdAt: card.createdAt,
            updatedAt: .now
        )
    }
}
