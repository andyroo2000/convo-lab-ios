import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testSourceEditWaitsForPendingCreationBeforeCallingServer() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            XCTFail("Pending local cards must not send metadata writes")
            return Self.response(data: Data("{}".utf8))
        }
        client.setAccessToken("test-token")
        let store = StudyStore(initialUserID: 1, api: client, context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext))
        let id = "01jzq4nny5xbnzw14q1g68b2yt"
        XCTAssertTrue(store.canEditCardPlacement(id: id))
        try store.cardOutbox.stageCreate(cardID: id, request: CreateStudyCardRequest(
            id: id, cardType: "recognition", prompt: .object([:]), answer: .object([:])
        ))
        XCTAssertFalse(store.canEditCardPlacement(id: id))
        do {
            try await store.assignCardSource(id: id, source: nil)
            XCTFail("Expected pending-write rejection")
        } catch let APIClientError.rejected(status, message) {
            XCTAssertEqual(status, 409)
            XCTAssertTrue(message.contains("Sync pending"))
        }
    }
}
