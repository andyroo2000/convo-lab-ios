import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testServerUpsertRetainsPendingDuplicateTargetedThroughItsSyncAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "local-id", syncId: "server-id", expression: "local edit")
        let pendingDuplicate = makeCard(id: "server-id", syncId: "pending-alias", expression: "pending duplicate")
        let server = makeCard(id: "server-id", expression: "fresh server")
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let pendingRecord = insert(pendingDuplicate, userID: 1, in: container)
        pendingRecord.locallyUpdatedAt = nil
        container.mainContext.insert(
            PendingMutation(kind: "cardUpdate", userID: 1, resourceID: "pending-alias", payload: Data()))
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        XCTAssertEqual(storedRecords.count, 2)
        XCTAssertTrue(storedRecords.contains { $0 === localRecord })
        XCTAssertTrue(storedRecords.contains { $0 === pendingRecord })
    }

    @MainActor
    func testServerUpsertDoesNotBorrowMediaReadinessFromDifferentAliasPayload() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id", syncId: "server-id", expression: "local edit", audioURL: "https://example.com/local.mp3")
        let staleCanonical = makeCard(
            id: "server-id", expression: "stale server", audioURL: "https://example.com/stale.mp3")
        let server = makeCard(id: "server-id", expression: "fresh server", audioURL: "https://example.com/server.mp3")
        let localRecord = insert(local, userID: 1, in: container)
        let canonicalRecord = insert(staleCanonical, userID: 1, in: container)
        canonicalRecord.mediaPreparedAt = Date(timeIntervalSince1970: 50)
        container.mainContext.insert(
            PendingMutation(kind: "cardUpdate", userID: 1, resourceID: local.id, payload: Data()))
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        let storedRecord = try XCTUnwrap(storedRecords.first)
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: storedRecord.payload)
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertTrue(storedRecord === localRecord)
        XCTAssertEqual(storedCard.mediaURLs, local.mediaURLs)
        XCTAssertNil(storedRecord.mediaPreparedAt)
    }

    @MainActor
    func testServerUpsertTraversesAliasChainWithoutDuplicatingRetainedDirtySessionRow() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "local-id", syncId: "bridge-id", expression: "newest local edit")
        let bridge = makeCard(id: "bridge-id", syncId: "server-id", expression: "older local edit")
        let staleCanonical = makeCard(id: "server-id", expression: "stale server")
        let server = makeCard(
            id: "server-id", expression: "fresh server", queueState: "learning", masteryLevel: "enlightened")
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.isInActiveSession = false
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let bridgeRecord = insert(bridge, userID: 1, in: container)
        bridgeRecord.queueIndex = 3
        bridgeRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 100)
        let canonicalRecord = insert(staleCanonical, userID: 1, in: container)
        canonicalRecord.isInActiveSession = false
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        let updatedLocal = try XCTUnwrap(storedRecords.first { $0.id == local.id })
        let updatedCard = try StorageCodec.decoder.decode(StudyCard.self, from: updatedLocal.payload)
        XCTAssertEqual(storedRecords.count, 2)
        XCTAssertTrue(updatedLocal === localRecord)
        XCTAssertTrue(storedRecords.contains { $0 === bridgeRecord })
        XCTAssertFalse(storedRecords.contains { $0 === canonicalRecord })
        XCTAssertEqual(updatedCard.promptText, "newest local edit")
        XCTAssertEqual(updatedCard.state.queueState, "learning")
        XCTAssertEqual(updatedCard.masteryLevel, "enlightened")
        XCTAssertTrue(updatedLocal.isInActiveSession)
        XCTAssertEqual(updatedLocal.queueIndex, 3)
        XCTAssertFalse(bridgeRecord.isInActiveSession)
        XCTAssertEqual(storedRecords.filter(\.isInActiveSession).count, 1)
    }

    @MainActor
    func testServerUpsertPreservesSchedulingFromPendingReviewAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let olderReviewed = makeCard(
            id: "a-reviewed-alias", syncId: "server-id", expression: "older reviewed copy", queueState: "learning",
            masteryLevel: "apprentice")
        let reviewed = makeCard(
            id: "reviewed-alias", syncId: "server-id", expression: "reviewed copy", queueState: "review",
            masteryLevel: "enlightened")
        let edited = makeCard(
            id: "edited-alias", syncId: "server-id", expression: "local edit", queueState: "learning",
            masteryLevel: "apprentice")
        let server = makeCard(
            id: "server-id", expression: "fresh server", queueState: "relearning", masteryLevel: "guru")
        let olderReviewedRecord = insert(olderReviewed, userID: 1, in: container)
        let reviewedRecord = insert(reviewed, userID: 1, in: container)
        let editedRecord = insert(edited, userID: 1, in: container)
        editedRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let olderReviewMutation = PendingMutation(
            kind: "review", userID: 1, resourceID: olderReviewed.id, payload: Data())
        olderReviewMutation.createdAt = Date(timeIntervalSince1970: 100)
        container.mainContext.insert(olderReviewMutation)
        let latestReviewMutation = PendingMutation(kind: "review", userID: 1, resourceID: reviewed.id, payload: Data())
        latestReviewMutation.createdAt = Date(timeIntervalSince1970: 200)
        container.mainContext.insert(latestReviewMutation)
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        let storedEdited = try XCTUnwrap(storedRecords.first { $0 === editedRecord })
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: storedEdited.payload)
        XCTAssertEqual(storedRecords.count, 3)
        XCTAssertTrue(storedRecords.contains { $0 === olderReviewedRecord })
        XCTAssertTrue(storedRecords.contains { $0 === reviewedRecord })
        XCTAssertEqual(storedCard.promptText, "local edit")
        XCTAssertEqual(storedCard.state.queueState, reviewed.state.queueState)
        XCTAssertEqual(storedCard.masteryLevel, reviewed.masteryLevel)
        XCTAssertTrue(storedEdited.isInActiveSession)
        XCTAssertFalse(olderReviewedRecord.isInActiveSession)
        XCTAssertFalse(reviewedRecord.isInActiveSession)
        XCTAssertEqual(storedRecords.filter(\.isInActiveSession).count, 1)
    }

    @MainActor
    func testPendingReviewPreservesSchedulingStateWithoutHidingServerContent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "reviewed", expression: "local text", queueState: "review", masteryLevel: "enlightened")
        let server = makeCard(id: local.id, expression: "server text", queueState: "learning", masteryLevel: "guru")
        let serverID = server.id
        let batchData = try Self.batchData([server])
        insert(local, userID: 1, in: container)
        container.mainContext.insert(PendingMutation(kind: "review", userID: 1, resourceID: local.id, payload: Data()))
        try container.mainContext.save()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let record = try XCTUnwrap(records(for: 1, in: container).first)
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
        XCTAssertEqual(storedCard.promptText, "server text")
        XCTAssertEqual(storedCard.state.queueState, "review")
        XCTAssertEqual(storedCard.masteryLevel, "enlightened")
        XCTAssertNil(record.locallyUpdatedAt)
        XCTAssertEqual(record.serverUpdatedAt, server.updatedAt)
    }

    @MainActor
    func testPendingDeletePreventsInboundUpsertFromRecreatingCard() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let server = makeCard(id: "deleted", expression: "server copy")
        let serverID = server.id
        let batchData = try Self.batchData([server])
        container.mainContext.insert(
            PendingMutation(kind: "cardDelete", userID: 1, resourceID: serverID.uppercased(), payload: Data()))
        try container.mainContext.save()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
    }
}
