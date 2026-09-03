import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testStartingActivityDuringPendingPushSchedulesAcknowledgementRetry() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let (pushStarted, pushStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releasePush, releasePushContinuation) = AsyncStream<Void>.makeStream()
        let pushCount = LockedCounter()
        let client = makeDeferredClient { request, completion in
            do {
                switch (request.httpMethod, request.url?.path) {
                case ("POST", "/api/study/activity-sessions/batch"):
                    let sessions = try Self.batchSessions(from: request)
                    let response = {
                        completion(.success(
                            try Self.jsonResponse(for: request, body: sessions)
                        ))
                    }
                    if pushCount.next() == 1 {
                        pushStartedContinuation.yield()
                        Task {
                            var releaseIterator = releasePush.makeAsyncIterator()
                            _ = await releaseIterator.next()
                            try response()
                        }
                    } else {
                        try response()
                    }
                case ("GET", "/api/study/activity-analytics"):
                    completion(.success(try analyticsResponse(for: request)))
                default:
                    XCTFail(
                        "Unexpected request: \(request.httpMethod ?? "") "
                            + "\(request.url?.path ?? "")"
                    )
                    completion(.failure(URLError(.badURL)))
                }
            } catch {
                completion(.failure(error))
            }
        }
        let store = StudyTimeStore(api: client, context: container.mainContext)
        let startedAt = Date(timeIntervalSince1970: 1_753_732_800)
        store.activate(userID: 42)

        let completed = Task {
            try await store.recordCompleted(
                activity: .conversation,
                source: .manual,
                name: "Conversation",
                startedAt: startedAt,
                duration: 30 * 60
            )
        }
        var pushStartedIterator = pushStarted.makeAsyncIterator()
        _ = await pushStartedIterator.next()

        store.start(
            activity: .cardReview,
            source: .automatic,
            at: startedAt.addingTimeInterval(2_000)
        )
        releasePushContinuation.yield()
        _ = try await completed.value

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        let saved = try XCTUnwrap(records.first { $0.endedAt != nil })
        XCTAssertFalse(saved.syncPending)
        XCTAssertEqual(pushCount.current, 2)
    }
}
