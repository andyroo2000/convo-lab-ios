import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testMalformedResponseLeavesCheckpointAndCardsUntouched() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let existing = makeCard(id: "existing", expression: "local")
        insert(existing, userID: 1, in: container)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 3))
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Data(#"{"data":[]}"#.utf8))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync { _ = try await repository.pullChanges() }

        XCTAssertEqual(try checkpoint(for: 1, in: container), 3)
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [existing.id])
    }

    @MainActor
    func testPendingLocalEditSurvivesServerUpsertAndDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "dirty", expression: "local edit", queueState: "review", masteryLevel: "guru")
        let server = makeCard(
            id: local.id, expression: "server edit", queueState: "learning", masteryLevel: "apprentice")
        let localID = local.id
        let serverBatchData = try Self.batchData([server])
        let record = insert(local, userID: 1, in: container)
        let dirtyAt = Date(timeIntervalSince1970: 100)
        record.locallyUpdatedAt = dirtyAt
        container.mainContext.insert(
            PendingMutation(kind: "cardUpdate", userID: 1, resourceID: local.id.uppercased(), payload: Data()))
        try container.mainContext.save()
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                if feedRequests.next() == 1 {
                    return Self.response(
                        data: Self.feedData(entries: [(1, localID, "update")], nextCheckpoint: 1, hasMore: false))
                }
                return Self.response(
                    data: Self.feedData(entries: [(2, localID, "delete")], nextCheckpoint: 2, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: serverBatchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        var storedRecord = try XCTUnwrap(records(for: 1, in: container).first)
        var storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: storedRecord.payload)
        XCTAssertEqual(storedCard.promptText, "local edit")
        XCTAssertEqual(storedCard.state.queueState, "learning")
        XCTAssertEqual(storedCard.masteryLevel, "apprentice")
        XCTAssertNotNil(storedRecord.locallyUpdatedAt)
        XCTAssertEqual(storedRecord.serverUpdatedAt, server.updatedAt)

        _ = try await repository.pullChanges()

        storedRecord = try XCTUnwrap(records(for: 1, in: container).first)
        storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: storedRecord.payload)
        XCTAssertEqual(storedCard.promptText, "local edit")
        XCTAssertEqual(storedRecord.locallyUpdatedAt, dirtyAt)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 2)
    }

    @MainActor
    func testPendingLocalEditDropsPresentationAfterRacingServerCardTypeChange() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = try withPresentation(makeCard(id: "type-race", expression: "same content"))
        let server = try withPresentation(makeCard(id: local.id, expression: "same content", cardType: "production"))
        let cardID = local.id
        let record = insert(local, userID: 1, in: container)
        record.locallyUpdatedAt = Date(timeIntervalSince1970: 100)
        container.mainContext.insert(
            PendingMutation(kind: "cardUpdate", userID: 1, resourceID: local.id, payload: Data()))
        try container.mainContext.save()
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, cardID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let stored = try XCTUnwrap(cards(for: 1, in: container).first)
        XCTAssertEqual(stored.cardType, "production")
        XCTAssertNil(stored.serverPresentation)
    }

    @MainActor
    func testQuarantinedEditDoesNotBlockLaterAuthoritativeServerUpsert() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "conflicted", expression: "resolved server snapshot")
        let server = makeCard(id: local.id, expression: "newer server edit")
        let localID = local.id
        insert(local, userID: 1, in: container)
        let quarantined = PendingMutation(
            kind: "cardUpdate", userID: 1, resourceID: local.id.uppercased(), payload: Data())
        quarantined.lastError = "HTTP 409 [card_revision_conflict]: stale edit"
        container.mainContext.insert(quarantined)
        try container.mainContext.save()
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(
                    data: Self.feedData(entries: [(1, localID, "update")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch": return Self.response(data: batchData)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let stored = try XCTUnwrap(try cards(for: 1, in: container).first)
        XCTAssertEqual(stored.promptText, "newer server edit")
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
        XCTAssertEqual(quarantined.lastError, "HTTP 409 [card_revision_conflict]: stale edit")
    }

    @MainActor
    func testServerUpsertReconcilesCanonicalDuplicateIntoDirtyLocalAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id", syncId: "server-id", expression: "local edit", queueState: "review", masteryLevel: "guru")
        let staleCanonical = makeCard(
            id: "server-id", expression: "stale server", queueState: "review", masteryLevel: "apprentice")
        let server = makeCard(
            id: "server-id", expression: "fresh server", queueState: "learning", masteryLevel: "enlightened")
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.isInActiveSession = false
        localRecord.queueIndex = 8
        let canonicalRecord = insert(staleCanonical, userID: 1, in: container)
        canonicalRecord.queueIndex = 2
        let preparedAt = Date(timeIntervalSince1970: 50)
        canonicalRecord.mediaPreparedAt = preparedAt
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
        var publishedCards = [local, staleCanonical]
        var publishedReconciler = StudyPublishedCardReconciler()

        _ = try await repository.pullChanges { changes in publishedReconciler.apply(changes, to: &publishedCards) }

        let storedRecords = try records(for: 1, in: container)
        let storedRecord = try XCTUnwrap(storedRecords.first)
        let storedCard = try StorageCodec.decoder.decode(StudyCard.self, from: storedRecord.payload)
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertTrue(storedRecord === localRecord)
        XCTAssertEqual(storedRecord.id, local.id)
        XCTAssertEqual(storedCard.id, local.id)
        XCTAssertEqual(storedCard.reviewCardID, serverID)
        XCTAssertEqual(storedCard.promptText, "local edit")
        XCTAssertEqual(storedCard.state.queueState, "learning")
        XCTAssertEqual(storedCard.masteryLevel, "enlightened")
        XCTAssertTrue(storedRecord.isInActiveSession)
        XCTAssertEqual(storedRecord.queueIndex, 2)
        XCTAssertEqual(storedRecord.mediaPreparedAt, preparedAt)
        XCTAssertEqual(storedRecord.serverUpdatedAt, server.updatedAt)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
        XCTAssertEqual(publishedCards.count, 1)
        XCTAssertEqual(publishedCards.first?.id, local.id)
        XCTAssertEqual(publishedCards.first?.promptText, "local edit")
    }
}
