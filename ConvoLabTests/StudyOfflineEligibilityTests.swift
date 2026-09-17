import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

@MainActor
final class StudyOfflineEligibilityTests: XCTestCase {
    func testUnavailableVariantsStayOutOfOfflineQueueAfterPersistence() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        for (index, status) in ["locked", "retired"].enumerated() {
            let card = try makeCard(id: "variant-\(index)", variantStatus: status)
            try save(card, in: container, active: index == 0)
        }
        let store = makeStore(container: container)
        defer { store.deactivate() }

        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertEqual(store.sessionCounts.reviewRemaining, 0)
        XCTAssertEqual(store.libraryCards.count, 2)
    }

    func testEmptySyncRepairsLegacyCacheAcrossRepeatedRelaunches() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let legacyCard = try makeCard(id: "legacy-card")
        let cardPath = "/api/study/cards/\(legacyCard.id)"
        try save(legacyCard, in: container, active: false)
        let lockedPayload = try cardPayload(id: legacyCard.id, variantStatus: "locked")
        let requests = LockedRequestPaths()
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url?.path)
            requests.append(path)
            let data = path == cardPath
                ? lockedPayload
                : try Self.emptySyncResponse(path: path)
            return (Self.response(for: request), data)
        }
        let store = makeStore(container: container, client: client)
        XCTAssertEqual(store.sessionCounts.reviewRemaining, 1)

        await store.synchronize()

        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertTrue(store.cards.isEmpty)
        store.deactivate()
        for _ in 0..<2 {
            let relaunched = makeStore(container: container, client: client)
            XCTAssertTrue(relaunched.cards.isEmpty)
            XCTAssertEqual(relaunched.sessionCounts.reviewRemaining, 0)
            await relaunched.synchronize()
            relaunched.deactivate()
        }
        XCTAssertEqual(requests.values.filter { $0.contains("/cards/") }.count, 1)
    }

    func testAvailableAndLegacyCardsStillBecomeDueOffline() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dueAt = Date.now.addingTimeInterval(3_600)
        for (index, status) in [nil, "available"].enumerated() {
            let card = try makeCard(id: "due-\(index)", variantStatus: status, dueAt: dueAt)
            try save(card, in: container, active: false)
        }
        let store = makeStore(container: container)
        defer { store.deactivate() }
        XCTAssertTrue(store.cards.isEmpty)

        store.activateOfflineDueCards(at: dueAt.addingTimeInterval(1))

        XCTAssertEqual(store.cards.count, 2)
        XCTAssertEqual(store.sessionCounts.reviewRemaining, 2)
    }

    private func makeStore(container: ModelContainer, client: APIClient? = nil) -> StudyStore {
        let api = client ?? makeClient { _ in throw URLError(.notConnectedToInternet) }
        return StudyStore(
            initialUserID: 1,
            api: api,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: api, context: container.mainContext)
        )
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    private func save(_ card: StudyCard, in container: ModelContainer, active: Bool) throws {
        let record = LocalCardRecord(
            card: card, userID: 1, queueIndex: 0,
            payload: try StorageCodec.encoder.encode(card)
        )
        record.isInActiveSession = active
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    private func makeCard(
        id: String, variantStatus: String? = nil, dueAt: Date = .distantPast
    ) throws -> StudyCard {
        try StorageCodec.decoder.decode(
            StudyCard.self,
            from: cardPayload(id: id, variantStatus: variantStatus, dueAt: dueAt)
        )
    }

    private func cardPayload(
        id: String, variantStatus: String? = nil, dueAt: Date = .distantPast
    ) throws -> Data {
        let timestamp = ISO8601DateFormatter().string(from: dueAt)
        var object: [String: Any] = [
            "id": id, "cardType": "recognition",
            "prompt": ["cueText": "復習"], "answer": ["meaning": "review"],
            "state": ["dueAt": timestamp, "queueState": "review", "source": [:]],
            "createdAt": "2026-07-01T12:00:00Z", "updatedAt": "2026-07-01T12:00:00Z",
        ]
        object["variantStatus"] = variantStatus
        return try JSONSerialization.data(withJSONObject: object)
    }

    nonisolated private static func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func emptySyncResponse(path: String) throws -> Data {
        let json: String
        switch path {
        case "/api/sync/feed":
            json = #"{"data":[],"meta":{"next_checkpoint":1234,"has_more":false}}"#
        case "/api/study/known-kanji":
            json = #"{"version":0,"kanji":[],"manualKanji":[],"wanikani":{"connected":false,"lastSyncedAt":null}}"#
        case "/api/study/session/start":
            json = #"{"cards":[],"overview":{"dueCount":0,"newCount":0,"reviewCount":0,"newCardsPerDay":10,"newCardsAvailableToday":0}}"#
        case "/api/study/offline-reserve":
            json = #"{"cards":[],"reserveDays":5,"generatedAt":"2026-07-25T12:00:00Z","horizonEndsAt":"2026-07-30T12:00:00Z"}"#
        default:
            throw URLError(.badURL)
        }
        return Data(json.utf8)
    }
}
