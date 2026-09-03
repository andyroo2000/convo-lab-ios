import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyActivitySessionTests: XCTestCase {
    // Confirmed with a weak saver and no unstructured task in the card-count
    // case: iOS 26 XCTest can double-free an injected SwiftData container at
    // method teardown. Keep this bounded set of six containers for the suite.
    static var retainedSaveFixtures: [AnyObject] = []

    func savedRecord(
        in container: ModelContainer
    ) throws -> LocalStudyActivitySession {
        try XCTUnwrap(
            container.mainContext.fetch(
                FetchDescriptor<LocalStudyActivitySession>()
            ).first
        )
    }

    func retainSaveFixtures(_ fixtures: AnyObject...) {
        Self.retainedSaveFixtures.append(contentsOf: fixtures)
    }

    func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.deferredHandler = nil
        MockURLProtocol.handler = handler
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: makeMockSession()
        )
    }

    func makeDeferredClient(
        handler: @escaping MockURLProtocol.DeferredHandler
    ) -> APIClient {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = handler
        return APIClient(
            baseURL: URL(string: "https://example.test")!,
            session: makeMockSession()
        )
    }

    func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated static func jsonResponse(
        for request: URLRequest,
        statusCode: Int = 200,
        body: Any
    ) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            try JSONSerialization.data(withJSONObject: body)
        )
    }

    nonisolated static func jsonResult(
        for request: URLRequest,
        statusCode: Int = 200,
        body: Any
    ) -> Result<(HTTPURLResponse, Data), Error> {
        Result {
            try Self.jsonResponse(for: request, statusCode: statusCode, body: body)
        }
    }

    nonisolated static func batchSessions(from request: URLRequest) throws -> [[String: Any]] {
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
        )
        return try XCTUnwrap(payload["sessions"] as? [[String: Any]])
    }

    static func sessionData(_ sessions: [StudyActivitySession]) throws -> Data {
        try JSONSerialization.data(withJSONObject: sessions.map { session in
            [
                "id": session.id as Any,
                "clientSessionId": session.clientSessionId,
                "category": session.category.rawValue,
                "activity": session.activity.rawValue,
                "source": session.source.rawValue,
                "origin": session.origin.rawValue,
                "name": session.name as Any,
                "startedAt": session.startedAt.ISO8601Format(),
                "endedAt": session.endedAt.ISO8601Format(),
                "durationMs": session.durationMs,
            ]
        })
    }
}
@MainActor
final class EmptyStudyTimeSnapshotCache: StudyTimeSnapshotCaching {
    func load(userID: Int, timeZone: String) -> StudyTimeSnapshot? { nil }
    func save(_ snapshot: StudyTimeSnapshot, userID: Int, timeZone: String) {}
    func remove(userID: Int) {}
}

@MainActor
final class DeterministicStudyTimeSaves: StudyTimeContextSaving {
    private weak var context: ModelContext?
    private let failingAttempts: Set<Int>
    private var attempt = 0

    init(context: ModelContext, failingAttempts: Set<Int>) {
        self.context = context
        self.failingAttempts = failingAttempts
    }

    func save() throws {
        attempt += 1
        if failingAttempts.contains(attempt) {
            throw DeterministicStudyTimeSaveError.forced
        }
        guard let context else {
            throw DeterministicStudyTimeSaveError.fixtureDeallocated
        }
        try context.save()
    }
}

@MainActor
final class DeterministicStudyCalendar: StudyCalendarProviding {
    struct Update: Equatable {
        let identifier: String
        let title: String
        let start: Date
        let end: Date
    }

    private(set) var deletedIdentifiers: [String] = []
    private(set) var updates: [Update] = []
    private var nextIdentifier = 1

    func addEvent(title: String, start: Date, end: Date) async throws -> String {
        defer { nextIdentifier += 1 }
        return "event-\(nextIdentifier)"
    }

    func updateEvent(
        identifier: String,
        title: String,
        start: Date,
        end: Date
    ) async throws {
        updates.append(.init(
            identifier: identifier,
            title: title,
            start: start,
            end: end
        ))
    }

    func deleteEvent(identifier: String) async throws {
        deletedIdentifiers.append(identifier)
    }
}

enum DeterministicStudyTimeSaveError: LocalizedError {
    case forced
    case fixtureDeallocated

    var errorDescription: String? {
        switch self {
        case .forced:
            "Forced save failure"
        case .fixtureDeallocated:
            "The test persistence fixture was deallocated"
        }
    }
}

func makeSession(
    source: StudyActivitySource,
    origin: StudyActivityOrigin = .ios,
    clientSessionId: String = "018f22d2-6d38-7000-8000-000000000099"
) -> StudyActivitySession {
    StudyActivitySession(
        id: "server-session-1",
        clientSessionId: clientSessionId,
        category: .immerse,
        activity: .tv,
        source: source,
        origin: origin,
        name: "Drama",
        startedAt: Date(timeIntervalSince1970: 1_753_732_800),
        endedAt: Date(timeIntervalSince1970: 1_753_734_600),
        durationMs: 1_800_000,
        audioPlaybackMs: nil,
        cardsCreated: nil
    )
}

func studyActivitySessionJSONObject() -> [String: Any] {
    [
        "id": "server-session-1",
        "clientSessionId": "018f22d2-6d38-7000-8000-000000000099",
        "category": "immerse",
        "activity": "tv",
        "source": "manual",
        "name": "Drama",
        "startedAt": "2026-07-28T20:00:00Z",
        "endedAt": "2026-07-28T20:30:00Z",
        "durationMs": 1_800_000,
    ]
}

func studyActivityJSON(
    id: String,
    clientSessionID: String,
    startedAt: String
) -> [String: Any] {
    [
        "id": id,
        "clientSessionId": clientSessionID,
        "category": "immerse",
        "activity": "tv",
        "source": "manual",
        "origin": "ios",
        "name": "Drama",
        "startedAt": startedAt,
        "endedAt": startedAt,
        "durationMs": 1_800_000,
    ]
}

func studyActivityDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

func analyticsResponse(
    for request: URLRequest,
    anchorDateOverride: String? = nil
) throws -> (HTTPURLResponse, Data) {
    let requestURL = try XCTUnwrap(request.url)
    let anchorDate = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == "anchorDate" }?
        .value ?? "2026-07-28"
    let body: [String: Any] = [
        "generatedAt": "2026-07-28T20:00:00Z",
        "anchorDate": anchorDateOverride ?? anchorDate,
        "timezone": "America/New_York",
        "ranges": [
            [
                "key": "week",
                "startsAt": "2026-07-27T04:00:00Z",
                "endsAt": "2026-07-28T20:00:00Z",
                "totalMs": 3_600_000,
                "categories": [
                    "review": 1_800_000,
                    "listen": 0,
                    "create": 0,
                    "immerse": 0,
                    "conversation": 1_800_000,
                    "wanikani": 0,
                ],
                "buckets": [
                    [
                        "startsAt": "2026-07-28T04:00:00Z",
                        "endsAt": "2026-07-28T20:00:00Z",
                        "totalMs": 3_600_000,
                        "categories": [
                            "review": 1_800_000,
                            "listen": 0,
                            "create": 0,
                            "immerse": 0,
                            "conversation": 1_800_000,
                            "wanikani": 0,
                        ],
                    ],
                ],
            ],
        ],
    ]
    return (
        HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!,
        try JSONSerialization.data(withJSONObject: body)
    )
}
