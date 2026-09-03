import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
extension StudyActivitySessionTests {
    func testFailedDeleteDoesNotBlockPendingUpdates() async throws {
        let container = try StudyTimePersistence.makeContainer(inMemory: true)
        let deletedSession = makeSession(source: .manual)
        let tombstone = LocalStudyActivitySession(session: deletedSession, userID: 42)
        tombstone.isTombstone = true
        tombstone.syncPending = true
        container.mainContext.insert(tombstone)

        let pendingSession = StudyActivitySession(
            id: "server-session-3",
            clientSessionId: "018f22d2-6d38-7000-8000-000000000101",
            category: .conversation,
            activity: .conversation,
            source: .manual,
            name: "Pending lesson",
            startedAt: Date(timeIntervalSince1970: 1_753_736_400),
            endedAt: Date(timeIntervalSince1970: 1_753_737_000),
            durationMs: 600_000,
            audioPlaybackMs: nil,
            cardsCreated: nil
        )
        let pending = LocalStudyActivitySession(session: pendingSession, userID: 42)
        pending.syncPending = true
        container.mainContext.insert(pending)
        try container.mainContext.save()
        let client = try makeFailedDeleteClient(
            deletedSession: deletedSession,
            pendingSession: pendingSession
        )
        let store = StudyTimeStore(api: client, context: container.mainContext)
        store.activate(userID: 42)

        await store.synchronize()

        let records = try container.mainContext.fetch(
            FetchDescriptor<LocalStudyActivitySession>()
        )
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(
            try XCTUnwrap(records.first { $0.clientSessionID == deletedSession.clientSessionId })
                .syncPending
        )
        XCTAssertFalse(
            try XCTUnwrap(records.first { $0.clientSessionID == pendingSession.clientSessionId })
                .syncPending
        )
        XCTAssertNotNil(store.syncErrorMessage)
    }

    private func makeFailedDeleteClient(
        deletedSession: StudyActivitySession,
        pendingSession: StudyActivitySession
    ) throws -> APIClient {
        let deletedSessionID = deletedSession.clientSessionId
        let pendingSessionID = pendingSession.clientSessionId
        let remoteSessionsData = try Self.sessionData([pendingSession])
        return makeClient { request in
            try Self.failedDeleteResponse(
                for: request,
                deletedSessionID: deletedSessionID,
                pendingSessionID: pendingSessionID,
                remoteSessionsData: remoteSessionsData
            )
        }
    }

    nonisolated private static func failedDeleteResponse(
        for request: URLRequest,
        deletedSessionID: String,
        pendingSessionID: String,
        remoteSessionsData: Data
    ) throws -> (HTTPURLResponse, Data) {
        let path = try XCTUnwrap(request.url).path
        let method = try XCTUnwrap(request.httpMethod)
        let handlers: [String: () throws -> (HTTPURLResponse, Data)] = [
            "DELETE /api/study/activity-sessions/\(deletedSessionID)": {
                try Self.jsonResponse(
                    for: request,
                    statusCode: 503,
                    body: ["message": "temporarily unavailable"]
                )
            },
            "POST /api/study/activity-sessions/batch": {
                let sessions = try Self.batchSessions(from: request)
                XCTAssertEqual(
                    try XCTUnwrap(sessions.first)["clientSessionId"] as? String,
                    pendingSessionID
                )
                return try Self.jsonResponse(for: request, body: sessions)
            },
            "GET /api/study/activity-sessions": {
                (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    remoteSessionsData
                )
            },
            "GET /api/study/activity-analytics": {
                try analyticsResponse(for: request)
            },
        ]
        guard let handler = handlers["\(method) \(path)"] else {
            XCTFail("Unexpected failed-delete synchronization request")
            throw URLError(.badURL)
        }
        return try handler()
    }
}
