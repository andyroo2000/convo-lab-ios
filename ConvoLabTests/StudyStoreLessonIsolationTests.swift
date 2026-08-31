import Foundation
import Observation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testLeavingSuccessfulLessonRestoresPersistedReviewQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(id: "persisted-review-card", expression: "復習")
        let lessonCard = makeCard(
            id: "presented-lesson-card",
            expression: "新しい項目",
            queueState: "new"
        )
        container.mainContext.insert(LocalCardRecord(
            card: reviewCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(reviewCard)
        ))
        try container.mainContext.save()
        let lessonData = try sessionResponseData(cards: [lessonCard], lessonBatchSize: 3)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/lessons/start":
                return Self.response(data: lessonData)
            case "/api/study/reviews/batch":
                throw URLError(.notConnectedToInternet)
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

        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])
        store.beginLessonSessionPresentation()
        XCTAssertTrue(store.cards.isEmpty)

        try await store.refreshLessons()

        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        XCTAssertEqual(store.sessionKind, "lessons")
        let recordedEventID = await store.recordReview(
            card: lessonCard,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertTrue(store.cards.isEmpty)
        try await store.undoReview(eventID: eventID, cardBefore: lessonCard)
        XCTAssertEqual(store.cards.map(\.id), [lessonCard.id])
        store.endLessonSessionPresentation()

        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])
        XCTAssertEqual(store.sessionKind, "reviews")
        let activeRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 1 && $0.isInActiveSession }
            )
        )
        XCTAssertEqual(activeRecords.map(\.id), [reviewCard.id])
    }

    @MainActor
    func testServerUndoStartedInLessonCannotEnterReviewsAfterLessonExit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let reviewCard = makeCard(id: "persisted-review-before-undo", expression: "復習")
        let lessonCard = makeCard(
            id: "lesson-with-delayed-undo",
            expression: "新しい項目",
            queueState: "new"
        )
        container.mainContext.insert(LocalCardRecord(
            card: reviewCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(reviewCard)
        ))
        try container.mainContext.save()
        let lessonData = try sessionResponseData(cards: [lessonCard])
        let lessonJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(lessonCard), encoding: .utf8)
        )
        let overview = StudyOverview(
            dueCount: 0,
            newCount: 1,
            reviewCount: 0,
            newCardsPerDay: 10,
            newCardsAvailableToday: 1
        )
        let overviewJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(overview), encoding: .utf8)
        )
        let undoGate = LockedRequestGate()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/study/lessons/start":
                return Self.response(data: lessonData)
            case "/api/card-review-events/batch":
                return Self.response(statusCode: 201, data: Data())
            case "/api/study/reviews/undo":
                undoGate.markStarted()
                undoGate.waitForRelease()
                return Self.response(data: Data(
                    """
                    {
                      "reviewLogId": "delayed-lesson-undo",
                      "card": \(lessonJSON),
                      "overview": \(overviewJSON)
                    }
                    """.utf8
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
            )
        )
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()
        let recordedEventID = await store.recordReview(
            card: lessonCard,
            rating: .again,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        XCTAssertEqual(store.sessionFailureCount, 1)

        let undoTask = Task {
            try await store.undoReview(eventID: eventID, cardBefore: lessonCard)
        }
        await waitUntil { undoGate.hasStarted }
        store.endLessonSessionPresentation()
        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])

        undoGate.release()
        try await undoTask.value

        XCTAssertEqual(store.cards.map(\.id), [reviewCard.id])
        XCTAssertEqual(store.sessionFailureCount, 1)
        let activeRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 1 && $0.isInActiveSession }
            )
        )
        XCTAssertEqual(activeRecords.map(\.id), [reviewCard.id])
    }

    @MainActor
    func testServerUndoFromOldLessonCannotEnterNewLessonBatch() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let oldLesson = makeCard(
            id: "old-lesson-with-delayed-undo",
            expression: "前の項目",
            queueState: "new"
        )
        let newLesson = makeCard(
            id: "new-lesson-batch",
            expression: "次の項目",
            queueState: "new"
        )
        let oldLessonData = try sessionResponseData(cards: [oldLesson])
        let newLessonData = try sessionResponseData(cards: [newLesson])
        let oldLessonJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(oldLesson), encoding: .utf8)
        )
        let overview = StudyOverview(
            dueCount: 0,
            newCount: 1,
            reviewCount: 0,
            newCardsPerDay: 10,
            newCardsAvailableToday: 1
        )
        let overviewJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(overview), encoding: .utf8)
        )
        let lessonRequests = LockedCounter()
        let deferredUndo = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch request.url?.path {
            case "/api/study/lessons/start":
                completion(.success(Self.response(
                    data: lessonRequests.next() == 1 ? oldLessonData : newLessonData
                )))
            case "/api/card-review-events/batch":
                completion(.success(Self.response(statusCode: 201, data: Data())))
            case "/api/study/reviews/undo":
                deferredUndo.hold(completion)
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let undoResponse = Self.response(data: Data(
            """
            {
              "reviewLogId": "old-lesson-delayed-undo",
              "card": \(oldLessonJSON),
              "overview": \(overviewJSON)
            }
            """.utf8
        ))
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
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()
        let recordedEventID = await store.recordReview(
            card: oldLesson,
            rating: .good,
            duration: nil
        )
        let eventID = try XCTUnwrap(recordedEventID)
        let undoTask = Task {
            try await store.undoReview(eventID: eventID, cardBefore: oldLesson)
        }
        await waitUntil { deferredUndo.hasPendingResponse }

        try await store.refreshLessons()
        XCTAssertEqual(store.cards.map(\.id), [newLesson.id])
        deferredUndo.succeed(with: undoResponse)
        try await undoTask.value

        XCTAssertEqual(store.cards.map(\.id), [newLesson.id])
        let activeRecords = try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == 1 && $0.isInActiveSession }
            )
        )
        XCTAssertTrue(activeRecords.isEmpty)
    }

    @MainActor
    func testCheckpointResetWhileServerUndoIsInFlightCannotRestoreActiveQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let resetCard = makeCard(
            id: "review-discarded-by-checkpoint-reset",
            expression: "再構築前の復習"
        )
        let record = LocalCardRecord(
            card: resetCard,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(resetCard)
        )
        record.isInActiveSession = true
        container.mainContext.insert(record)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 99))
        try container.mainContext.save()

        let cardJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(resetCard), encoding: .utf8)
        )
        let overview = StudyOverview(
            dueCount: 1,
            newCount: 0,
            reviewCount: 1,
            newCardsPerDay: 10,
            newCardsAvailableToday: 0
        )
        let overviewJSON = try XCTUnwrap(
            String(data: StorageCodec.encoder.encode(overview), encoding: .utf8)
        )
        let deferredUndo = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            switch request.url?.path {
            case "/api/study/reviews/undo":
                deferredUndo.hold(completion)
            case "/api/sync/feed":
                completion(.success(Self.response(
                    statusCode: 409,
                    data: Data(#"{"message":"Checkpoint expired"}"#.utf8)
                )))
            case "/api/study/known-kanji":
                completion(.success(Self.response(data: Data(
                    #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#.utf8
                ))))
            default:
                completion(.failure(URLError(.notConnectedToInternet)))
            }
        }
        let undoResponse = Self.response(data: Data(
            """
            {
              "reviewLogId": "undo-crossing-checkpoint-reset",
              "card": \(cardJSON),
              "overview": \(overviewJSON)
            }
            """.utf8
        ))
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
        XCTAssertEqual(store.cards.map(\.id), [resetCard.id])

        let undoTask = Task {
            try await store.undoReview(
                eventID: "undo-crossing-checkpoint-reset",
                cardBefore: resetCard
            )
        }
        await waitUntil { deferredUndo.hasPendingResponse }

        await store.synchronize()
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(
            try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty
        )

        deferredUndo.succeed(with: undoResponse)
        try await undoTask.value

        XCTAssertTrue(store.cards.isEmpty)
        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.map(\.id), [resetCard.id])
        XCTAssertFalse(try XCTUnwrap(records.first).isInActiveSession)
    }

    @MainActor
    func testOfflineDueCardsCannotEnterPresentedLesson() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date.now.addingTimeInterval(3_600)
        let offlineReview = makeCard(
            id: "offline-review-due-during-lesson",
            expression: "後で復習",
            dueAt: dueAt
        )
        let record = LocalCardRecord(
            card: offlineReview,
            userID: 1,
            queueIndex: 0,
            payload: try StorageCodec.encoder.encode(offlineReview)
        )
        record.isInActiveSession = false
        container.mainContext.insert(record)
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
        XCTAssertTrue(store.cards.isEmpty)

        store.beginLessonSessionPresentation()
        store.activateOfflineDueCards(at: dueAt.addingTimeInterval(1))

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertFalse(record.isInActiveSession)
    }

    @MainActor
    func testLessonRefreshUsesDedicatedEndpointAndStartsFrozenBatchProgress() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let lessonCards = [
            makeCard(
                id: "01J00000000000000000000014",
                expression: "営業する",
                queueState: "new"
            ),
            makeCard(
                id: "01J00000000000000000000015",
                expression: "講義",
                queueState: "new"
            ),
        ]
        let canonicalizedDuplicate = makeCard(
            id: lessonCards[0].id.lowercased(),
            expression: "営業する",
            queueState: "new"
        )
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 3,
                newCount: 8,
                reviewCount: 3,
                newCardsPerDay: 20,
                newCardsAvailableToday: 8,
                lessonBatchSize: 2
            ),
            cards: [lessonCards[0], canonicalizedDuplicate, lessonCards[1]]
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/api/card-review-events/batch" {
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
            XCTAssertTrue(
                ["/api/study/lessons/start", "/api/study/session/start"].contains(path)
            )
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
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        store.beginLessonSessionPresentation()
        try await store.refreshLessons()

        XCTAssertEqual(store.cards.map(\.id), lessonCards.map(\.id))
        XCTAssertEqual(store.sessionKind, "lessons")
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(store.sessionInitialCardCount, 2)

        store.retryLessonCard(lessonCards[0])

        XCTAssertEqual(store.cards.map(\.id), [lessonCards[1].id, lessonCards[0].id])
        XCTAssertEqual(store.sessionProgress, 0)
        XCTAssertEqual(store.cards.map(\.state.queueState), ["new", "new"])

        let refreshedWhilePresented = try await store.refreshSessionPreservingActiveLessons()

        XCTAssertFalse(refreshedWhilePresented)
        XCTAssertEqual(paths.values, ["/api/study/lessons/start"])
        XCTAssertEqual(store.sessionKind, "lessons")
        XCTAssertEqual(store.cards.map(\.id), [lessonCards[1].id, lessonCards[0].id])

        let eventID = await store.recordReview(
            card: lessonCards[1],
            rating: .good,
            duration: nil
        )

        XCTAssertNotNil(eventID)
        XCTAssertEqual(store.cards.map(\.id), [lessonCards[0].id])
        XCTAssertEqual(store.sessionProgress, 0.5)
        XCTAssertEqual(
            paths.values,
            ["/api/study/lessons/start", "/api/card-review-events/batch"]
        )

        store.endLessonSessionPresentation()
        XCTAssertTrue(store.cards.isEmpty)
        let refreshedAfterLeaving = try await store.refreshSessionPreservingActiveLessons()

        XCTAssertTrue(refreshedAfterLeaving)
        XCTAssertEqual(store.sessionKind, "reviews")
        XCTAssertEqual(
            paths.values,
            [
                "/api/study/lessons/start",
                "/api/card-review-events/batch",
                "/api/study/session/start",
            ]
        )

        store.beginLessonSessionPresentation()
        store.deactivate()
        store.activate(userID: 1)
        let refreshedAfterReactivation = try await store.refreshSessionPreservingActiveLessons()

        XCTAssertTrue(refreshedAfterReactivation)
        XCTAssertEqual(paths.values.last, "/api/study/session/start")
    }

    @MainActor
    func testLessonRefreshTrustsServerCardCount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let lessonCards = (0..<50).map { index in
            makeCard(
                id: String(format: "01J%023d", index),
                expression: "Lesson card \(index)",
                queueState: "new"
            )
        }
        let session = StudySession(
            overview: StudyOverview(
                dueCount: 0,
                newCount: 50,
                reviewCount: 0,
                newCardsPerDay: 50,
                newCardsAvailableToday: 50,
                lessonBatchSize: 5
            ),
            cards: lessonCards
        )
        let object = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let data = try JSONSerialization.data(withJSONObject: ["data": object])
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/lessons/start")
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

        try await store.refreshLessons()

        XCTAssertEqual(store.cards.map(\.id), lessonCards.map(\.id))
        XCTAssertEqual(store.sessionInitialCardCount, lessonCards.count)
        XCTAssertEqual(store.overview?.lessonBatchSize, 5)
    }

    @MainActor
    func testLessonFollowupCohortRemainsActiveAcrossBatchesAndClearsOnExit() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let lessonCard = makeCard(
            id: "cohort-lesson-card",
            expression: "会話",
            queueState: "new"
        )
        let lessonData = try sessionResponseData(cards: [lessonCard], lessonBatchSize: 3)
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            paths.append(request.url?.path ?? "nil")
            return Self.response(data: lessonData)
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

        let ordinaryPresentationID = UUID()
        let cohortPresentationID = UUID()
        XCTAssertTrue(store.beginLessonSessionPresentation(
            presentationID: ordinaryPresentationID
        ))
        XCTAssertNil(store.activeLessonCohortID)
        XCTAssertFalse(store.beginLessonSessionPresentation(
            presentationID: cohortPresentationID,
            cohortID: "01K00000000000000000000000"
        ))
        XCTAssertNil(store.activeLessonCohortID)
        store.endLessonSessionPresentation(presentationID: ordinaryPresentationID)
        XCTAssertTrue(store.beginLessonSessionPresentation(
            presentationID: cohortPresentationID,
            cohortID: "01K00000000000000000000000"
        ))
        XCTAssertEqual(store.activeLessonCohortID, "01K00000000000000000000000")
        try await store.refreshLessons()
        try await store.refreshLessons()
        store.endLessonSessionPresentation(presentationID: ordinaryPresentationID)
        XCTAssertEqual(store.activeLessonCohortID, "01K00000000000000000000000")
        store.endLessonSessionPresentation(presentationID: cohortPresentationID)
        store.beginLessonSessionPresentation()
        try await store.refreshLessons()

        XCTAssertEqual(paths.values, [
            "/api/study/introduction-cohorts/01K00000000000000000000000/lessons/start",
            "/api/study/introduction-cohorts/01K00000000000000000000000/lessons/start",
            "/api/study/lessons/start",
        ])
    }
}
