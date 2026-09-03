import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testDeactivationInvalidatesAnalyticsBeforePendingPushSuspends() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let pendingSession = LocalStudyActivitySession(
            session: makeSession(source: .manual),
            userID: 42
        )
        pendingSession.syncPending = true
        container.mainContext.insert(pendingSession)
        try container.mainContext.save()

        let (analyticsStarted, analyticsStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseAnalytics, releaseAnalyticsContinuation) = AsyncStream<Void>.makeStream()
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/study/activity-analytics"):
                analyticsStartedContinuation.yield()
                Task {
                    do {
                        var iterator = releaseAnalytics.makeAsyncIterator()
                        _ = await iterator.next()
                        completion(.success(try analyticsResponse(for: request)))
                    } catch {
                        completion(.failure(error))
                    }
                }
            case ("POST", "/api/study/activity-sessions/batch"):
                pushStartedContinuation.yield()
                Task {
                    do {
                        var iterator = releasePush.makeAsyncIterator()
                        _ = await iterator.next()
                        completion(.success(
                            try Self.jsonResponse(
                                for: request,
                                body: Self.batchSessions(from: request)
                            )
                        ))
                    } catch {
                        completion(.failure(error))
                    }
                }
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let store = StudyTimeStore(
            api: client,
            context: container.mainContext,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        store.activate(userID: 42)

        let analyticsTask = Task {
            await store.loadAnalytics(anchorDate: Date(timeIntervalSince1970: 1_753_732_800))
        }
        var analyticsStartedIterator = analyticsStarted.makeAsyncIterator()
        _ = await analyticsStartedIterator.next()

        let deactivationTask = Task { await store.deactivate() }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()
        releaseAnalyticsContinuation.yield()
        _ = await analyticsTask.value

        XCTAssertNil(store.analytics)
        XCTAssertTrue(store.analyticsCache.isEmpty)

        releasePushContinuation.yield()
        let didDeactivate = await deactivationTask.value
        XCTAssertTrue(didDeactivate)
    }

    func testJoinedSynchronizationMarksTheLeadersOutcomeAsNonApplying() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (getStarted, getStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseGet, releaseGetContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/study/activity-sessions"):
                getStartedContinuation.yield()
                Task {
                    var iterator = releaseGet.makeAsyncIterator()
                    _ = await iterator.next()
                    completion(.success((
                        HTTPURLResponse(
                            url: request.url!,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        Data("[]".utf8)
                    )))
                }
            case ("GET", "/api/study/activity-analytics"):
                do {
                    completion(.success(try analyticsResponse(for: request)))
                } catch {
                    completion(.failure(error))
                }
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
        let insights = StudyTimeInsightsController(
            api: client,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        let coordinator = StudyTimeSynchronizationCoordinator(
            api: client,
            repository: StudyTimeSessionMutationRepository(
                api: client,
                context: container.mainContext,
                storageMode: .persistent,
                contextSaver: nil,
                calendar: nil
            ),
            insights: insights
        )
        insights.activate(userID: 42)
        coordinator.activate(userID: 42)

        let leader = Task { await coordinator.synchronize() }
        var getStartedIterator = getStarted.makeAsyncIterator()
        _ = await getStartedIterator.next()
        let joiner = Task { await coordinator.synchronize() }
        await Task.yield()
        releaseGetContinuation.yield()

        let leaderOutcome = await leader.value
        let joinedOutcome = await joiner.value
        XCTAssertEqual(leaderOutcome?.shouldApply, true)
        XCTAssertEqual(joinedOutcome?.shouldApply, false)
    }

    func testJoinedPendingPushMarksTheLeadersOutcomeAsNonApplying() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let pendingSession = LocalStudyActivitySession(
            session: makeSession(source: .manual),
            userID: 42
        )
        pendingSession.syncPending = true
        container.mainContext.insert(pendingSession)
        try container.mainContext.save()
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            guard request.httpMethod == "POST",
                  request.url?.path == "/api/study/activity-sessions/batch"
            else {
                completion(.failure(URLError(.badURL)))
                return
            }
            pushStartedContinuation.yield()
            Task {
                var iterator = releasePush.makeAsyncIterator()
                _ = await iterator.next()
                do {
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: requestBody(request))
                            as? [String: Any]
                    )
                    let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
                    completion(.success((
                        HTTPURLResponse(
                            url: try XCTUnwrap(request.url),
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        try JSONSerialization.data(withJSONObject: sessions)
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        let insights = StudyTimeInsightsController(
            api: client,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        let coordinator = StudyTimeSynchronizationCoordinator(
            api: client,
            repository: StudyTimeSessionMutationRepository(
                api: client,
                context: container.mainContext,
                storageMode: .persistent,
                contextSaver: nil,
                calendar: nil
            ),
            insights: insights
        )
        coordinator.activate(userID: 42)

        let leader = Task { await coordinator.pushPending() }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()
        let joiner = Task { await coordinator.pushPending() }
        await Task.yield()
        releasePushContinuation.yield()

        let leaderOutcome = await leader.value
        let joinedOutcome = await joiner.value
        XCTAssertEqual(leaderOutcome?.shouldApply, true)
        XCTAssertEqual(joinedOutcome?.shouldApply, false)
    }

    func testSynchronizationSurfacesFailureFromAJoinedPendingPush() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let pendingSession = LocalStudyActivitySession(
            session: makeSession(source: .manual),
            userID: 42
        )
        pendingSession.syncPending = true
        container.mainContext.insert(pendingSession)
        try container.mainContext.save()
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let pushCount = LockedCounter()
        let client = makeJoinedPushFailureClient(
            pushStarted: pushStartedContinuation,
            releasePush: releasePush,
            pushCount: pushCount
        )
        let insights = StudyTimeInsightsController(
            api: client,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        let coordinator = StudyTimeSynchronizationCoordinator(
            api: client,
            repository: StudyTimeSessionMutationRepository(
                api: client,
                context: container.mainContext,
                storageMode: .persistent,
                contextSaver: nil,
                calendar: nil
            ),
            insights: insights
        )
        insights.activate(userID: 42)
        coordinator.activate(userID: 42)

        let pushLeader = Task { await coordinator.pushPending() }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()
        let synchronization = Task { await coordinator.synchronize() }
        await Task.yield()
        releasePushContinuation.yield()

        let pushOutcome = await pushLeader.value
        let synchronizationOutcome = await synchronization.value
        XCTAssertNotNil(pushOutcome?.failureMessage)
        XCTAssertEqual(
            synchronizationOutcome?.failureMessage,
            pushOutcome?.failureMessage
        )
        XCTAssertEqual(synchronizationOutcome?.shouldApply, true)
    }

    func testSynchronizationSurfacesFailureAfterConcurrentLocalMutation() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (getStarted, getStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseGet, releaseGetContinuation) = AsyncStream<Void>.makeStream()
        let client = makeDeferredClient { request, completion in
            guard request.httpMethod == "GET",
                  request.url?.path == "/api/study/activity-sessions"
            else {
                completion(.failure(URLError(.badURL)))
                return
            }
            getStartedContinuation.yield()
            Task {
                var iterator = releaseGet.makeAsyncIterator()
                _ = await iterator.next()
                completion(.success((
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(#"{"message":"Synchronization unavailable"}"#.utf8)
                )))
            }
        }
        let store = StudyTimeStore(
            api: client,
            context: container.mainContext,
            snapshotCache: EmptyStudyTimeSnapshotCache()
        )
        store.activate(userID: 42)

        let synchronization = Task { await store.synchronize() }
        var getStartedIterator = getStarted.makeAsyncIterator()
        _ = await getStartedIterator.next()
        try store.deleteLocalData(userID: 42)
        releaseGetContinuation.yield()
        await synchronization.value

        XCTAssertNotNil(store.syncErrorMessage)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.active)
    }

    private func makeJoinedPushFailureClient(
        pushStarted: AsyncStream<Void>.Continuation,
        releasePush: AsyncStream<Void>,
        pushCount: LockedCounter
    ) -> APIClient {
        makeDeferredClient { request, completion in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/study/activity-sessions/batch"):
                let response = {
                    completion(Self.jsonResult(
                        for: request,
                        statusCode: 503,
                        body: ["message": "Push unavailable"]
                    ))
                }
                if pushCount.next() == 1 {
                    pushStarted.yield()
                    Task {
                        var iterator = releasePush.makeAsyncIterator()
                        _ = await iterator.next()
                        response()
                    }
                } else {
                    response()
                }
            case ("GET", "/api/study/activity-sessions"):
                completion(Self.jsonResult(for: request, body: []))
            case ("GET", "/api/study/activity-analytics"):
                completion(Result { try analyticsResponse(for: request) })
            default:
                completion(.failure(URLError(.badURL)))
            }
        }
    }
}
