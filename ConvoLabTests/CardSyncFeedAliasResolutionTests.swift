import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testDeletionAndPendingChecksResolveLocalIDAndSyncIDInBothDirections() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let feedUsesSyncID = makeCard(id: "local-forward", syncId: "server-forward", expression: "forward")
        let feedUsesLocalID = makeCard(id: "server-reverse", syncId: "local-reverse", expression: "reverse")
        insert(feedUsesSyncID, userID: 1, in: container)
        insert(feedUsesLocalID, userID: 1, in: container)
        container.mainContext.insert(
            PendingMutation(kind: "cardUpdate", userID: 1, resourceID: feedUsesSyncID.id, payload: Data()))
        container.mainContext.insert(
            PendingMutation(
                kind: "cardUpdate", userID: 1, resourceID: try XCTUnwrap(feedUsesLocalID.syncId), payload: Data()))
        try container.mainContext.save()
        let forwardFeedID = try XCTUnwrap(feedUsesSyncID.syncId)
        let reverseFeedID = feedUsesLocalID.id
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            let isFirstPage = feedRequests.next() == 1
            return Self.response(
                data: Self.feedData(
                    entries: [
                        (isFirstPage ? 1 : 3, forwardFeedID, "delete"), (isFirstPage ? 2 : 4, reverseFeedID, "delete"),
                    ], nextCheckpoint: isFirstPage ? 2 : 4, hasMore: false))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(Set(try cards(for: 1, in: container).map(\.id)), Set([feedUsesSyncID.id, feedUsesLocalID.id]))
        for mutation in try container.mainContext.fetch(FetchDescriptor<PendingMutation>()) {
            container.mainContext.delete(mutation)
        }
        try container.mainContext.save()

        let deletionResult = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(
            deletionResult,
            .completed(deletedCardIdentifiers: [
                feedUsesSyncID.id, forwardFeedID, reverseFeedID, try XCTUnwrap(feedUsesLocalID.syncId),
            ]))
        XCTAssertEqual(try checkpoint(for: 1, in: container), 4)
    }

    @MainActor
    func testServerDeleteTraversesEntireAliasChain() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "local-id", syncId: "bridge-id", expression: "local")
        let bridge = makeCard(id: "bridge-id", syncId: "server-id", expression: "bridge")
        insert(local, userID: 1, in: container)
        insert(bridge, userID: 1, in: container)
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(
                data: Self.feedData(entries: [(1, "server-id", "delete")], nextCheckpoint: 1, hasMore: false))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertTrue(try records(for: 1, in: container).isEmpty)
        XCTAssertEqual(result, .completed(deletedCardIdentifiers: ["local-id", "bridge-id", "server-id"]))
    }

    @MainActor
    func testAliasLookupNeverCrossesAccountBoundary() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let userOneCard = makeCard(id: "user-one-local", syncId: "shared-server-id", expression: "user one")
        let userTwoCard = makeCard(id: "user-two-local", syncId: "shared-server-id", expression: "user two")
        insert(userOneCard, userID: 1, in: container)
        insert(userTwoCard, userID: 2, in: container)
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(
                data: Self.feedData(entries: [(1, "shared-server-id", "delete")], nextCheckpoint: 1, hasMore: false))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(try cards(for: 2, in: container).map(\.id), ["user-two-local"])
    }

    @MainActor
    func testDeleteFindsMixedCaseLocalIDWithDistinctSyncAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "MixedCase-ID", syncId: "different-server-alias", expression: "mixed case")
        insert(card, userID: 1, in: container)
        try container.mainContext.save()
        let cardID = card.id
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(
                data: Self.feedData(entries: [(1, cardID, "delete")], nextCheckpoint: 1, hasMore: false))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(result, .completed(deletedCardIdentifiers: ["mixedcase-id", "different-server-alias"]))
    }

    @MainActor
    func testMultiPageFeedQueriesOnlyMatchingAliasRecords() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let libraryCards = (0..<10).map {
            makeCard(id: "local-\($0)", syncId: "server-\($0)", expression: "card \($0)")
        }
        for card in libraryCards { insert(card, userID: 1, in: container) }
        try container.mainContext.save()
        let firstSyncID = try XCTUnwrap(libraryCards[0].syncId)
        let secondSyncID = try XCTUnwrap(libraryCards[1].syncId)
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            let isFirstPage = feedRequests.next() == 1
            return Self.response(
                data: Self.feedData(
                    entries: [(isFirstPage ? 1 : 2, isFirstPage ? firstSyncID : secondSyncID, "delete")],
                    nextCheckpoint: isFirstPage ? 1 : 2, hasMore: isFirstPage))
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onIndexingRecord: { _ = indexedRecords.next() })
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 2)
        XCTAssertEqual(try cards(for: 1, in: container).count, libraryCards.count - 2)
    }
}
