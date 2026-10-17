import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testLargeFeedQueriesOutboxAndActiveCountOncePerPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let first = (0..<50).map { makeCard(id: "card-\($0)", expression: "First \($0)") }
        let second = (50..<100).map { makeCard(id: "card-\($0)", expression: "Second \($0)") }
        for index in 0..<100 {
            container.mainContext.insert(PendingMutation(
                kind: "cardUpdate", userID: 1, resourceID: "unrelated-\(index)", payload: Data()
            ))
        }
        try container.mainContext.save()
        let pages = try [first, second].enumerated().map { page, cards in
            let entries = cards.enumerated().map { index, card in
                (Int64(page * 50 + index + 1), card.id, "create")
            }
            return (
                feed: Self.feedData(entries: entries, nextCheckpoint: Int64((page + 1) * 50), hasMore: page == 0),
                batch: try Self.batchData(cards)
            )
        }
        let feedRequests = LockedCounter()
        let batchRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed": return Self.response(data: pages[feedRequests.next() - 1].feed)
            case "/api/study/cards/batch": return Self.response(data: pages[batchRequests.next() - 1].batch)
            default: throw URLError(.unsupportedURL)
            }
        }
        var queries: [CardSyncFeedRepository.CommitQuery] = []
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onCommitQuery: { queries.append($0) }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let stored = try records(for: 1, in: container)
        XCTAssertEqual(stored.count, 100)
        XCTAssertEqual(stored.map(\.queueIndex).sorted(), Array(0..<100))
        XCTAssertEqual(queries.filter { $0 == .pendingMutations }.count, 2)
        XCTAssertEqual(queries.filter { $0 == .activeCardCount }.count, 2)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 100)
    }

    @MainActor
    func testCachedActiveCountTracksDeletesAndAliasConsolidationWithinPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        insert(makeCard(id: "removed", expression: "Removed"), userID: 1, in: container)
        let local = insert(makeCard(id: "local", syncId: "server", expression: "Local edit"), userID: 1, in: container)
        local.locallyUpdatedAt = .now
        insert(makeCard(id: "server", expression: "Duplicate"), userID: 1, in: container)
        insert(makeCard(id: "other-account", expression: "Unrelated"), userID: 2, in: container)
        try container.mainContext.save()
        let cards = ["first", "server", "last"].map { makeCard(id: $0, expression: $0) }
        let batch = try Self.batchData(cards)
        let feed = Self.feedData(entries: [
            (1, "first", "create"), (2, "removed", "delete"), (3, "server", "update"),
            (4, "server", "update"), (5, "last", "create"),
        ], nextCheckpoint: 5, hasMore: false)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed": return Self.response(data: feed)
            case "/api/study/cards/batch": return Self.response(data: batch)
            default: throw URLError(.unsupportedURL)
            }
        }
        var queryCount = 0
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext,
            onCommitQuery: { if $0 == .activeCardCount { queryCount += 1 } }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let stored = try records(for: 1, in: container)
        XCTAssertEqual(Set(stored.map(\.id)), ["first", "local", "last"])
        XCTAssertEqual(stored.first { $0.id == "first" }?.queueIndex, 3)
        XCTAssertEqual(stored.first { $0.id == "last" }?.queueIndex, 2)
        XCTAssertEqual(stored.filter(\.isInActiveSession).count, 3)
        XCTAssertEqual(queryCount, 1)
        XCTAssertEqual(try records(for: 2, in: container).count, 1)
    }

    @MainActor
    func testNextPageSeesNewPendingDeleteAndChangedActiveCount() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let first = makeCard(id: "first", expression: "First")
        let deleted = makeCard(id: "deleted", expression: "Deleted")
        let last = makeCard(id: "last", expression: "Last")
        let firstBatch = try Self.batchData([first])
        let secondBatch = try Self.batchData([deleted, last])
        let requests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let isFirst = requests.next() == 1
                return Self.response(data: Self.feedData(
                    entries: isFirst ? [(1, "first", "create")] : [(2, "deleted", "create"), (3, "last", "create")],
                    nextCheckpoint: isFirst ? 1 : 3, hasMore: isFirst
                ))
            case "/api/study/cards/batch":
                return Self.response(data: try Self.batchIDs(in: request) == ["first"] ? firstBatch : secondBatch)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)
        var committedPages = 0

        _ = try await repository.pullChanges { _ in
            committedPages += 1
            guard committedPages == 1 else { return }
            container.mainContext.insert(PendingMutation(
                kind: "cardDelete", userID: 1, resourceID: "DELETED", payload: Data()
            ))
            let record = self.insert(self.makeCard(id: "local", expression: "Local"), userID: 1, in: container)
            record.queueIndex = 1
            try! container.mainContext.save()
        }

        let stored = try records(for: 1, in: container)
        XCTAssertEqual(Set(stored.map(\.id)), ["first", "local", "last"])
        XCTAssertEqual(stored.first { $0.id == "last" }?.queueIndex, 2)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 3)
    }

    @MainActor
    func testCancellationDuringCommitRollsBackPageAndCheckpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let batch = try Self.batchData([
            makeCard(id: "first", expression: "First"), makeCard(id: "second", expression: "Second"),
        ])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, "first", "create"), (2, "second", "create")], nextCheckpoint: 2, hasMore: false
                ))
            case "/api/study/cards/batch": return Self.response(data: batch)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext,
            beforeApplyingEntry: { index in
                if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        )
        repository.activate(userID: 1)
        let pull = Task { try await repository.pullChanges() }

        do {
            _ = try await pull.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The page must be retried; its first insertion was not committed.
        }

        XCTAssertEqual(try records(for: 1, in: container).count, 0)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testCancellationAfterPagePublicationStopsBeforeFetchingAnotherPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let removed = makeCard(id: "removed", expression: "Removed")
        insert(removed, userID: 1, in: container)
        try container.mainContext.save()
        let requests = LockedCounter()
        let client = makeClient { _ in
            _ = requests.next()
            return Self.response(data: Self.feedData(
                entries: [(1, "removed", "delete")], nextCheckpoint: 1, hasMore: true
            ))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)
        var publishedDeletes: Set<String> = []
        let pull = Task {
            try await repository.pullChanges { changes in
                publishedDeletes.formUnion(changes.deletedCardIdentifiers)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        do {
            _ = try await pull.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Publication must match the committed checkpoint before cancellation exits.
        }

        XCTAssertEqual(publishedDeletes, ["removed"])
        XCTAssertEqual(requests.current, 1)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
        XCTAssertTrue(try records(for: 1, in: container).isEmpty)
    }

    @MainActor
    func testEmptyPageDoesNotQueryCommitSnapshots() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let client = makeClient { _ in
            Self.response(data: Self.feedData(entries: [], nextCheckpoint: 0, hasMore: false))
        }
        var queries = 0
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onCommitQuery: { _ in queries += 1 }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(queries, 0)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
    }
}
