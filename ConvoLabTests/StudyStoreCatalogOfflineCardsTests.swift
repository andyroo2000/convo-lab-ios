import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testAllCardsFallsBackToTheLocalReplicaWhenOffline() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dog = makeCard(id: "01J00000000000000000000021", expression: "犬")
        let cat = makeCard(id: "01J00000000000000000000022", expression: "猫")
        for (index, card) in [dog, cat].enumerated() {
            container.mainContext.insert(
                LocalCardRecord(
                    card: card, userID: 1, queueIndex: index, payload: try StorageCodec.encoder.encode(card)))
        }
        try container.mainContext.save()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }
        let store = StudyStore(
            initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))

        do {
            try await store.refreshAllCards(search: "犬")
            XCTFail("Expected the remote card page to fail while offline")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }

        XCTAssertEqual(store.allCards.map(\.id), [dog.id])
        XCTAssertEqual(store.allCardsQuery, "犬")
        XCTAssertNil(store.allCardsNextCursor)
    }
}
