import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testStalePendingPushCannotAcknowledgeAReactivatedSessionsNewerEdit() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()

        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let pushCount = LockedCounter()
        let client = makeReactivationPushClient(
            pushStarted: pushStartedContinuation,
            releasePush: releasePush,
            pushCount: pushCount
        )
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        let oldEdit = Task {
            try await store.update(
                session: original,
                activity: .conversation,
                name: "Old edit",
                startedAt: original.startedAt,
                duration: 30 * 60
            )
        }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()

        store.activate(userID: 43)
        store.activate(userID: 42)
        let reactivatedSession = try XCTUnwrap(store.sessions.first)
        let newEdit = Task {
            try await store.update(
                session: reactivatedSession,
                activity: .conversation,
                name: "New edit",
                startedAt: reactivatedSession.startedAt,
                duration: 45 * 60
            )
        }
        for _ in 0..<100 where store.sessions.first?.name != "New edit" {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.sessions.first?.name, "New edit")
        releasePushContinuation.yield()
        _ = try await (oldEdit.value, newEdit.value)

        let saved = try XCTUnwrap(
            container.mainContext.fetch(FetchDescriptor<LocalStudyActivitySession>()).first
        )
        XCTAssertEqual(saved.name, "New edit")
        XCTAssertFalse(saved.syncPending)
        XCTAssertEqual(pushCount.current, 2)
    }

    private func makeReactivationPushClient(
        pushStarted: AsyncStream<Void>.Continuation,
        releasePush: AsyncStream<Void>,
        pushCount: LockedCounter
    ) -> APIClient {
        makeDeferredClient { request, completion in
            do {
                switch (request.httpMethod, request.url?.path) {
                case ("POST", "/api/study/activity-sessions/batch"):
                    let sessions = try Self.batchSessions(from: request)
                    if pushCount.next() == 1 {
                        pushStarted.yield()
                        Task {
                            var releaseIterator = releasePush.makeAsyncIterator()
                            _ = await releaseIterator.next()
                            completion(.success(
                                try Self.jsonResponse(for: request, body: sessions)
                            ))
                        }
                    } else {
                        XCTAssertEqual(sessions.first?["name"] as? String, "New edit")
                        completion(.success(
                            try Self.jsonResponse(for: request, body: sessions)
                        ))
                    }
                case ("GET", "/api/study/activity-analytics"):
                    completion(.success(try analyticsResponse(for: request)))
                default:
                    XCTFail("Unexpected reactivation push request")
                    completion(.failure(URLError(.badURL)))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
