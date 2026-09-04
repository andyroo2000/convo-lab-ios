import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testLearningPathLoadBlocksPendingPredecessorWriteBeforeNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let predecessor = makeCard(
            id: "01J0000000000000000000000LP",
            syncId: "01J0000000000000000000000LS",
            expression: "会社"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: predecessor,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(predecessor)
            )
        )
        let pendingUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: predecessor.reviewCardID,
            payload: try StorageCodec.encoder.encode(
                UpdateStudyCardRequest(prompt: predecessor.prompt, answer: predecessor.answer)
            )
        )
        container.mainContext.insert(pendingUpdate)
        try container.mainContext.save()
        let requestCounter = LockedCounter()
        let client = makeClient { _ in
            _ = requestCounter.next()
            throw URLError(.badServerResponse)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            _ = try await store.learningPath(for: predecessor)
            XCTFail("Expected a pending predecessor edit to block learning path loading")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Sync this card’s pending changes before editing its learning path."
            )
        }
        XCTAssertEqual(requestCounter.current, 0)
    }

    @MainActor
    func testLearningPathLinkBlocksPendingUncachedSuccessorWriteBeforeNetwork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let predecessor = makeCard(
            id: "01J0000000000000000000000LQ",
            expression: "会社"
        )
        let successor = makeCard(
            id: "01J0000000000000000000000LR",
            syncId: "01J0000000000000000000000LT",
            expression: "会社員"
        )
        container.mainContext.insert(
            LocalCardRecord(
                card: predecessor,
                userID: 1,
                queueIndex: 0,
                payload: try StorageCodec.encoder.encode(predecessor)
            )
        )
        let pendingUpdate = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: successor.id,
            payload: try StorageCodec.encoder.encode(
                UpdateStudyCardRequest(prompt: successor.prompt, answer: successor.answer)
            )
        )
        container.mainContext.insert(pendingUpdate)
        try container.mainContext.save()
        let requestCounter = LockedCounter()
        let client = makeClient { _ in
            _ = requestCounter.next()
            throw URLError(.badServerResponse)
        }
        let store = StudyStore(
            initialUserID: 1,
            api: client,
            context: container.mainContext,
            mediaCache: MediaCache(initialUserID: 1, api: client, context: container.mainContext)
        )

        do {
            _ = try await store.linkLearningPathSuccessor(
                successor,
                to: predecessor,
                requirement: .guru
            )
            XCTFail("Expected a pending successor edit to block learning path linking")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Sync this card’s pending changes before editing its learning path."
            )
        }
        XCTAssertEqual(requestCounter.current, 0)
    }

}
