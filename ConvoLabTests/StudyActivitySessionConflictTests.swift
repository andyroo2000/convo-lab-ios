import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testCompletedEditIsNotOverwrittenByAStaleInFlightRefresh() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let original = makeSession(source: .manual)
        container.mainContext.insert(
            LocalStudyActivitySession(session: original, userID: 42)
        )
        try container.mainContext.save()

        let (getStarted, getStartedContinuation) = AsyncStream<Void>.makeStream()
        let (releaseStaleGet, releaseStaleGetContinuation) = AsyncStream<Void>.makeStream()
        let staleBody = try Self.sessionData([original])
        let client = makeDeferredClient { request, completion in
            do {
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/study/activity-sessions"):
                    getStartedContinuation.yield()
                    Task {
                        var releaseIterator = releaseStaleGet.makeAsyncIterator()
                        _ = await releaseIterator.next()
                        completion(.success((
                            HTTPURLResponse(
                                url: try XCTUnwrap(request.url),
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: ["Content-Type": "application/json"]
                            )!,
                            staleBody
                        )))
                    }
                case ("POST", "/api/study/activity-sessions/batch"):
                    completion(.success(
                        try Self.jsonResponse(
                            for: request,
                            body: Self.batchSessions(from: request)
                        )
                    ))
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
        store.activate(userID: 42)
        let syncTask = Task { await store.synchronize() }
        var getStartedIterator = getStarted.makeAsyncIterator()
        _ = await getStartedIterator.next()
        defer { releaseStaleGetContinuation.yield() }

        _ = try await store.update(
            session: original,
            activity: .conversation,
            name: "Edited lesson",
            startedAt: original.startedAt,
            duration: 45 * 60
        )
        releaseStaleGetContinuation.yield()
        await syncTask.value

        let saved = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(saved.activity, .conversation)
        XCTAssertEqual(saved.name, "Edited lesson")
        XCTAssertEqual(saved.durationMs, 2_700_000)
    }
}
