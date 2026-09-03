import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testSequentialUpsertPullsReuseUnchangedAliasIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let libraryCards = (0..<10).map { makeCard(id: "card-\($0)", expression: "card \($0)") }
        for card in libraryCards { insert(card, userID: 1, in: container) }
        try container.mainContext.save()
        let serverCard = makeCard(id: libraryCards[0].id, expression: "fresh server")
        let serverCardID = serverCard.id
        let batchData = try Self.batchData([serverCard])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let checkpoint = feedRequests.next()
                return Self.response(
                    data: Self.feedData(
                        entries: [(Int64(checkpoint), serverCardID, "update")], nextCheckpoint: Int64(checkpoint),
                        hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onIndexingRecord: { _ = indexedRecords.next() })
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()
        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 1)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 2)
        XCTAssertEqual(try cards(for: 1, in: container).first?.promptText, "fresh server")
    }

    @MainActor
    func testSavedRecordBetweenPullsInvalidatesCachedAliasIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let libraryCards = (0..<10).map { makeCard(id: "card-\($0)", expression: "card \($0)") }
        for card in libraryCards { insert(card, userID: 1, in: container) }
        try container.mainContext.save()
        let insertedServerCard = makeCard(id: "inserted-card", expression: "fresh server")
        let firstServerCard = makeCard(id: libraryCards[0].id, expression: "first server")
        let insertedServerCardID = insertedServerCard.id
        let firstServerCardID = firstServerCard.id
        let firstData = try Self.batchData([firstServerCard])
        let insertedData = try Self.batchData([insertedServerCard])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let checkpoint = feedRequests.next()
                return Self.response(
                    data: Self.feedData(
                        entries: [
                            (Int64(checkpoint), checkpoint == 1 ? firstServerCardID : insertedServerCardID, "update")
                        ], nextCheckpoint: Int64(checkpoint), hasMore: false))
            case "/api/study/cards/batch":
                let ids = try Self.batchIDs(in: request)
                return Self.response(data: ids == [firstServerCardID] ? firstData : insertedData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onIndexingRecord: { _ = indexedRecords.next() })
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()
        insert(makeCard(id: insertedServerCardID, expression: "inserted local"), userID: 1, in: container)
        try container.mainContext.save()
        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 2)
        let inserted = try XCTUnwrap(cards(for: 1, in: container).first { $0.id == insertedServerCardID })
        XCTAssertEqual(inserted.promptText, "fresh server")
    }

    @MainActor
    func testUnrelatedSaveDoesNotInvalidateCachedAliasLookups() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localCard = makeCard(id: "card-1", expression: "local")
        insert(localCard, userID: 1, in: container)
        try container.mainContext.save()
        let serverCard = makeCard(id: localCard.id, expression: "server")
        let serverCardID = serverCard.id
        let batchData = try Self.batchData([serverCard])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let checkpoint = feedRequests.next()
                return Self.response(
                    data: Self.feedData(
                        entries: [(Int64(checkpoint), serverCardID, "update")], nextCheckpoint: Int64(checkpoint),
                        hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onIndexingRecord: { _ = indexedRecords.next() })
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()
        container.mainContext.insert(LocalKnownKanjiSnapshot(userID: 1, payload: Data("unrelated".utf8)))
        try container.mainContext.save()
        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 1)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 2)
    }

    @MainActor
    func testEmptyFeedDoesNotBuildAliasIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        for index in 0..<10 {
            insert(makeCard(id: "card-\(index)", expression: "card \(index)"), userID: 1, in: container)
        }
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Self.feedData(entries: [], nextCheckpoint: 0, hasMore: false))
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext, onIndexingRecord: { _ = indexedRecords.next() })
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 0)
        XCTAssertEqual(try cards(for: 1, in: container).count, 10)
    }

    @MainActor
    func testDirtyCardIgnoresTombstoneAndIsNotReportedAsDeleted() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dirty = makeCard(id: "local-dirty", syncId: "server-dirty", expression: "local edit")
        let record = insert(dirty, userID: 1, in: container)
        record.locallyUpdatedAt = .now
        try container.mainContext.save()
        let feedID = try XCTUnwrap(dirty.syncId)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(
                data: Self.feedData(entries: [(1, feedID, "delete")], nextCheckpoint: 1, hasMore: false))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertEqual(result, .completed(deletedCardIdentifiers: []))
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [dirty.id])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
    }
}
