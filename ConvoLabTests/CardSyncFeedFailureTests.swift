import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testMalformedAdvancingPageDoesNotApplyCardsOrMoveCheckpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 8))
        try container.mainContext.save()
        let batchRequests = LockedCounter()
        let emptyBatchData = try Self.batchData([])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(9, "card-1", "update")], nextCheckpoint: 8, hasMore: true))
            case "/api/study/cards/batch":
                _ = batchRequests.next()
                return Self.response(data: emptyBatchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        do {
            _ = try await repository.pullChanges()
            XCTFail("Expected a non-advancing paginated cursor to fail.")
        } catch let error as CardSyncFeedRepository.RepositoryError {
            guard case .invalidPage = error else { return XCTFail("Unexpected repository error: \(error)") }
        }

        XCTAssertEqual(batchRequests.current, 0)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 8)
        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
    }

    @MainActor
    func testFailedSecondPageKeepsFirstPageAndItsCheckpointRetryable() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let firstCard = makeCard(id: "card-1", expression: "committed")
        let firstCardID = firstCard.id
        let firstBatchData = try Self.batchData([firstCard])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                if feedRequests.next() == 1 {
                    return Self.response(
                        data: Self.feedData(entries: [(1, firstCardID, "create")], nextCheckpoint: 1, hasMore: true))
                }
                return Self.response(statusCode: 500, data: Data(#"{"message":"Unavailable"}"#.utf8))
            case "/api/study/cards/batch": return Self.response(data: firstBatchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync { _ = try await repository.pullChanges() }

        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [firstCard.id])
    }

    @MainActor
    func testMidPageApplicationFailureRollsBackEveryEntryAndCheckpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let updateOriginal = makeCard(id: "update", expression: "original update")
        let deleteOriginal = makeCard(id: "delete", expression: "original delete")
        insert(updateOriginal, userID: 1, in: container)
        insert(deleteOriginal, userID: 1, in: container)
        try container.mainContext.save()
        let updateServer = makeCard(id: updateOriginal.id, expression: "server update")
        let insertServer = makeCard(id: "insert", expression: "server insert")
        let trailingServer = makeCard(id: "trailing", expression: "never applied")
        let updateID = updateServer.id
        let deleteID = deleteOriginal.id
        let insertID = insertServer.id
        let trailingID = trailingServer.id
        let batchData = try Self.batchData([updateServer, insertServer, trailingServer])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(
                        entries: [
                            (1, updateID, "update"), (2, deleteID, "delete"), (3, insertID, "create"),
                            (4, trailingID, "create"),
                        ], nextCheckpoint: 4, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext,
            beforeApplyingEntry: { index in if index == 3 { throw InjectedPageFailure() } })
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync { _ = try await repository.pullChanges() }

        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        let restoredCards = try cards(for: 1, in: container)
        XCTAssertEqual(restoredCards.map(\.id), [deleteOriginal.id, updateOriginal.id])
        XCTAssertEqual(restoredCards.first(where: { $0.id == updateOriginal.id })?.promptText, "original update")
        XCTAssertEqual(restoredCards.first(where: { $0.id == deleteOriginal.id })?.promptText, "original delete")
        XCTAssertFalse(restoredCards.contains(where: { $0.id == insertServer.id }))
    }

    @MainActor
    func testLaterEntryFailureRollsBackAbsorbedAliasAndSurvivorChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id", syncId: "server-id", expression: "original local", audioURL: "https://example.com/local.mp3"
        )
        let canonical = makeCard(
            id: "server-id", expression: "original canonical", audioURL: "https://example.com/server.mp3")
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.isInActiveSession = false
        localRecord.queueIndex = 8
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let canonicalRecord = insert(canonical, userID: 1, in: container)
        canonicalRecord.queueIndex = 2
        let preparedAt = Date(timeIntervalSince1970: 100)
        canonicalRecord.mediaPreparedAt = preparedAt
        try container.mainContext.save()
        let server = makeCard(id: canonical.id, expression: "fresh server", audioURL: "https://example.com/server.mp3")
        let trailing = makeCard(id: "trailing", expression: "never applied")
        let serverID = server.id
        let trailingID = trailing.id
        let batchData = try Self.batchData([server, trailing])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(
                        entries: [(1, serverID, "update"), (2, trailingID, "create")], nextCheckpoint: 2, hasMore: false
                    ))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client, context: container.mainContext,
            beforeApplyingEntry: { index in if index == 1 { throw InjectedPageFailure() } })
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync { _ = try await repository.pullChanges() }

        let restoredRecords = try records(for: 1, in: container)
        XCTAssertEqual(restoredRecords.count, 2)
        XCTAssertTrue(restoredRecords.contains { $0 === localRecord })
        XCTAssertTrue(restoredRecords.contains { $0 === canonicalRecord })
        let restoredLocal = try StorageCodec.decoder.decode(StudyCard.self, from: localRecord.payload)
        let restoredCanonical = try StorageCodec.decoder.decode(StudyCard.self, from: canonicalRecord.payload)
        XCTAssertEqual(restoredLocal.promptText, "original local")
        XCTAssertEqual(restoredCanonical.promptText, "original canonical")
        XCTAssertFalse(localRecord.isInActiveSession)
        XCTAssertEqual(localRecord.queueIndex, 8)
        XCTAssertTrue(canonicalRecord.isInActiveSession)
        XCTAssertEqual(canonicalRecord.queueIndex, 2)
        XCTAssertNil(localRecord.mediaPreparedAt)
        XCTAssertEqual(canonicalRecord.mediaPreparedAt, preparedAt)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
    }

    @MainActor
    func testDirtySharedContextIsRefusedWithoutRollingBackUnrelatedWork() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let existing = makeCard(id: "existing", expression: "unrelated")
        let record = insert(existing, userID: 1, in: container)
        try container.mainContext.save()
        record.queueIndex = 42
        XCTAssertTrue(container.mainContext.hasChanges)
        let requestCount = LockedCounter()
        let client = makeClient { _ in
            _ = requestCount.next()
            throw URLError(.unsupportedURL)
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        do {
            _ = try await repository.pullChanges()
            XCTFail("Expected sync to refuse a dirty shared context.")
        } catch let error as CardSyncFeedRepository.RepositoryError {
            guard case .uncommittedLocalChanges = error else { return XCTFail("Unexpected repository error: \(error)") }
        }

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertEqual(record.queueIndex, 42)
        XCTAssertTrue(container.mainContext.hasChanges)
    }
}
