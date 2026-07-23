import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class StudyStoreTests: XCTestCase {
    @MainActor
    func testDeletingOfflineCreatedCardDoesNotResurrectIt() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )

        try await store.createCard(expression: "犬", reading: "いぬ", meaning: "dog")
        let card = try XCTUnwrap(store.cards.first)
        let cardData = try StorageCodec.encoder.encode(card)

        MockURLProtocol.handler = { request in
            if request.httpMethod == "DELETE" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 204,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                cardData
            )
        }

        try await store.deleteCard(card)

        let localCards = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        let pending = try container.mainContext.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertTrue(localCards.isEmpty)
        XCTAssertTrue(pending.filter { $0.kind.hasPrefix("card") }.isEmpty)
    }

    @MainActor
    func testRefreshKeepsLocallyDirtyCardInActiveQueue() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        let mediaCache = MediaCache(api: client, context: container.mainContext)
        let store = StudyStore(
            api: client,
            context: container.mainContext,
            mediaCache: mediaCache
        )
        try await store.createCard(expression: "猫", reading: "ねこ", meaning: "cat")
        let card = try XCTUnwrap(store.cards.first)
        let session = StudySession(
            overview: StudyOverview(
                newCount: 1,
                reviewCount: 0,
                newCardsPerDay: 10,
                newCardsAvailableToday: 1
            ),
            cards: [card]
        )
        let sessionObject = try JSONSerialization.jsonObject(
            with: StorageCodec.encoder.encode(session)
        )
        let envelopeData = try JSONSerialization.data(withJSONObject: ["data": sessionObject])
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                envelopeData
            )
        }

        try await store.refreshSession()

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(try XCTUnwrap(records.first).isInActiveSession)
        XCTAssertNotNil(records.first?.locallyUpdatedAt)
    }

    @MainActor
    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }
}
