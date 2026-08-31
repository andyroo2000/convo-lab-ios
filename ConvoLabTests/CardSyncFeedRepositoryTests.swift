import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class CardSyncFeedRepositoryTests: XCTestCase {
    @MainActor
    func testPullPaginatesFromPersistedCheckpointAndAdvancesAfterEachPage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 4))
        try container.mainContext.save()
        let firstCard = makeCard(id: "card-1", expression: "一")
        let secondCard = makeCard(id: "card-2", expression: "二")
        let firstCardID = firstCard.id
        let secondCardID = secondCard.id
        let firstBatchData = try Self.batchData([firstCard])
        let secondBatchData = try Self.batchData([secondCard])
        let feedRequests = LockedCounter()
        let requestedCheckpoints = LockedRequestPaths()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let checkpoint = Self.queryValue("after_checkpoint", in: request)
                requestedCheckpoints.append(checkpoint ?? "missing")
                XCTAssertEqual(Self.queryValue("domain", in: request), "flashcards")
                XCTAssertEqual(Self.queryValue("resource_type", in: request), "card")
                XCTAssertEqual(Self.queryValue("per_page", in: request), "50")
                if feedRequests.next() == 1 {
                    return Self.response(data: Self.feedData(
                        entries: [(5, firstCardID, "update")],
                        nextCheckpoint: 5,
                        hasMore: true
                    ))
                }
                return Self.response(data: Self.feedData(
                    entries: [(6, secondCardID, "create")],
                    nextCheckpoint: 6,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                XCTAssertEqual(request.httpMethod, "POST")
                let ids = try Self.batchIDs(in: request)
                return Self.response(data: ids == [firstCardID] ? firstBatchData : secondBatchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext
        )
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertEqual(result, .completed(deletedCardIdentifiers: []))
        XCTAssertEqual(requestedCheckpoints.values, ["4", "5"])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 6)
        XCTAssertEqual(Set(try cards(for: 1, in: container).map(\.id)), ["card-1", "card-2"])
    }

    @MainActor
    func testOrdinaryLeanFeedMergePreservesProgressionLock() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "progression-card",
            expression: "local",
            variantGroupID: "family-1",
            variantStatus: "locked"
        )
        let server = makeCard(id: local.id, expression: "server")
        let localID = local.id
        insert(local, userID: 1, in: container)
        try container.mainContext.save()
        let batchData = try Self.batchData(
            [server],
            omittingProgressionMetadata: true
        )
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, localID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let persisted = try XCTUnwrap(try cards(for: 1, in: container).first)
        XCTAssertEqual(persisted.promptText, "server")
        XCTAssertEqual(persisted.variantGroupId, "family-1")
        XCTAssertEqual(persisted.variantStatus, "locked")
    }

    @MainActor
    func testFeedEntryOrderControlsDeleteAndUpsertOutcome() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let restored = makeCard(id: "restored", expression: "restored-server")
        let removed = makeCard(id: "removed", expression: "removed-server")
        let restoredID = restored.id
        let removedID = removed.id
        let batchData = try Self.batchData([restored, removed])
        insert(makeCard(id: restored.id, expression: "restored-local"), userID: 1, in: container)
        insert(makeCard(id: removed.id, expression: "removed-local"), userID: 1, in: container)
        try container.mainContext.save()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [
                        (1, restoredID, "delete"),
                        (2, restoredID, "update"),
                        (3, removedID, "update"),
                        (4, removedID, "delete"),
                    ],
                    nextCheckpoint: 4,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                XCTAssertEqual(try Self.batchIDs(in: request), [restoredID, removedID])
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        let stored = try cards(for: 1, in: container)
        XCTAssertEqual(result, .completed(deletedCardIdentifiers: [removed.id]))
        XCTAssertEqual(stored.map(\.id), [restored.id])
        XCTAssertEqual(stored.first?.promptText, "restored-server")
        XCTAssertEqual(try checkpoint(for: 1, in: container), 4)
    }

    @MainActor
    func testLaterPageUpsertCancelsEarlierPageDeletionSignal() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let card = makeCard(id: "restored-across-pages", expression: "server")
        let cardID = card.id
        insert(makeCard(id: card.id, expression: "local"), userID: 1, in: container)
        try container.mainContext.save()
        let feedRequests = LockedCounter()
        let batchData = try Self.batchData([card])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let isFirstPage = feedRequests.next() == 1
                return Self.response(data: Self.feedData(
                    entries: [(isFirstPage ? 1 : 2, cardID, isFirstPage ? "delete" : "update")],
                    nextCheckpoint: isFirstPage ? 1 : 2,
                    hasMore: isFirstPage
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)
        var committedPages: [CardSyncFeedRepository.CommittedPageChanges] = []

        let result = try await repository.pullChanges { changes in
            committedPages.append(changes)
        }

        XCTAssertEqual(result, .completed(deletedCardIdentifiers: []))
        XCTAssertEqual(committedPages.count, 2)
        XCTAssertEqual(committedPages[0].deletedCardIdentifiers, [card.id])
        XCTAssertTrue(committedPages[0].restoredCards.isEmpty)
        XCTAssertTrue(committedPages[1].deletedCardIdentifiers.isEmpty)
        XCTAssertEqual(committedPages[1].restoredCards.map(\.card.promptText), ["server"])
        XCTAssertEqual(committedPages[1].restoredCards.map(\.identifiers), [[card.id]])
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [card.id])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 2)
    }

    @MainActor
    func testSavedLocalAliasBetweenPagesInvalidatesCachedIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let first = makeCard(id: "first-card", expression: "first")
        let target = makeCard(id: "server-target", expression: "server target")
        let firstID = first.id
        let targetID = target.id
        let firstData = try Self.batchData([first])
        let targetData = try Self.batchData([target])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let isFirstPage = feedRequests.next() == 1
                return Self.response(data: Self.feedData(
                    entries: [(
                        isFirstPage ? 1 : 2,
                        isFirstPage ? firstID : targetID,
                        "update"
                    )],
                    nextCheckpoint: isFirstPage ? 1 : 2,
                    hasMore: isFirstPage
                ))
            case "/api/study/cards/batch":
                let ids = try Self.batchIDs(in: request)
                return Self.response(data: ids == [firstID] ? firstData : targetData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            onIndexingRecord: { _ = indexedRecords.next() }
        )
        repository.activate(userID: 1)
        let committedPages = LockedCounter()
        var insertedAlias: LocalCardRecord?

        _ = try await repository.pullChanges { _ in
            guard committedPages.next() == 1 else { return }
            let localAlias = makeCard(
                id: "local-target",
                syncId: targetID,
                expression: "local target"
            )
            let record = insert(localAlias, userID: 1, in: container)
            record.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
            try! container.mainContext.save()
            insertedAlias = record
        }

        let storedRecords = try records(for: 1, in: container)
        let storedAlias = try XCTUnwrap(insertedAlias)
        let storedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: storedAlias.payload
        )
        XCTAssertEqual(storedRecords.count, 2)
        XCTAssertTrue(storedRecords.contains { $0 === storedAlias })
        XCTAssertFalse(storedRecords.contains { $0.id == targetID })
        XCTAssertEqual(storedCard.promptText, "local target")
        XCTAssertEqual(indexedRecords.current, 1)
    }

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
                return Self.response(data: Self.feedData(
                    entries: [(9, "card-1", "update")],
                    nextCheckpoint: 8,
                    hasMore: true
                ))
            case "/api/study/cards/batch":
                _ = batchRequests.next()
                return Self.response(data: emptyBatchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        do {
            _ = try await repository.pullChanges()
            XCTFail("Expected a non-advancing paginated cursor to fail.")
        } catch let error as CardSyncFeedRepository.RepositoryError {
            guard case .invalidPage = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
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
                    return Self.response(data: Self.feedData(
                        entries: [(1, firstCardID, "create")],
                        nextCheckpoint: 1,
                        hasMore: true
                    ))
                }
                return Self.response(
                    statusCode: 500,
                    data: Data(#"{"message":"Unavailable"}"#.utf8)
                )
            case "/api/study/cards/batch":
                return Self.response(data: firstBatchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.pullChanges()
        }

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
                return Self.response(data: Self.feedData(
                    entries: [
                        (1, updateID, "update"),
                        (2, deleteID, "delete"),
                        (3, insertID, "create"),
                        (4, trailingID, "create"),
                    ],
                    nextCheckpoint: 4,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            beforeApplyingEntry: { index in
                if index == 3 {
                    throw InjectedPageFailure()
                }
            }
        )
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.pullChanges()
        }

        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        let restoredCards = try cards(for: 1, in: container)
        XCTAssertEqual(restoredCards.map(\.id), [deleteOriginal.id, updateOriginal.id])
        XCTAssertEqual(
            restoredCards.first(where: { $0.id == updateOriginal.id })?.promptText,
            "original update"
        )
        XCTAssertEqual(
            restoredCards.first(where: { $0.id == deleteOriginal.id })?.promptText,
            "original delete"
        )
        XCTAssertFalse(restoredCards.contains(where: { $0.id == insertServer.id }))
    }

    @MainActor
    func testLaterEntryFailureRollsBackAbsorbedAliasAndSurvivorChanges() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id",
            syncId: "server-id",
            expression: "original local",
            audioURL: "https://example.com/local.mp3"
        )
        let canonical = makeCard(
            id: "server-id",
            expression: "original canonical",
            audioURL: "https://example.com/server.mp3"
        )
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.isInActiveSession = false
        localRecord.queueIndex = 8
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let canonicalRecord = insert(canonical, userID: 1, in: container)
        canonicalRecord.queueIndex = 2
        let preparedAt = Date(timeIntervalSince1970: 100)
        canonicalRecord.mediaPreparedAt = preparedAt
        try container.mainContext.save()
        let server = makeCard(
            id: canonical.id,
            expression: "fresh server",
            audioURL: "https://example.com/server.mp3"
        )
        let trailing = makeCard(id: "trailing", expression: "never applied")
        let serverID = server.id
        let trailingID = trailing.id
        let batchData = try Self.batchData([server, trailing])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [
                        (1, serverID, "update"),
                        (2, trailingID, "create"),
                    ],
                    nextCheckpoint: 2,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            beforeApplyingEntry: { index in
                if index == 1 {
                    throw InjectedPageFailure()
                }
            }
        )
        repository.activate(userID: 1)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.pullChanges()
        }

        let restoredRecords = try records(for: 1, in: container)
        XCTAssertEqual(restoredRecords.count, 2)
        XCTAssertTrue(restoredRecords.contains { $0 === localRecord })
        XCTAssertTrue(restoredRecords.contains { $0 === canonicalRecord })
        let restoredLocal = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: localRecord.payload
        )
        let restoredCanonical = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: canonicalRecord.payload
        )
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
            guard case .uncommittedLocalChanges = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
        }

        XCTAssertEqual(requestCount.current, 0)
        XCTAssertEqual(record.queueIndex, 42)
        XCTAssertTrue(container.mainContext.hasChanges)
    }

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

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.pullChanges()
        }

        XCTAssertEqual(try checkpoint(for: 1, in: container), 3)
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [existing.id])
    }

    @MainActor
    func testPendingLocalEditSurvivesServerUpsertAndDelete() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "dirty",
            expression: "local edit",
            queueState: "review",
            masteryLevel: "guru"
        )
        let server = makeCard(
            id: local.id,
            expression: "server edit",
            queueState: "learning",
            masteryLevel: "apprentice"
        )
        let localID = local.id
        let serverBatchData = try Self.batchData([server])
        let record = insert(local, userID: 1, in: container)
        let dirtyAt = Date(timeIntervalSince1970: 100)
        record.locallyUpdatedAt = dirtyAt
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: local.id.uppercased(),
            payload: Data()
        ))
        try container.mainContext.save()
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                if feedRequests.next() == 1 {
                    return Self.response(data: Self.feedData(
                        entries: [(1, localID, "update")],
                        nextCheckpoint: 1,
                        hasMore: false
                    ))
                }
                return Self.response(data: Self.feedData(
                    entries: [(2, localID, "delete")],
                    nextCheckpoint: 2,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: serverBatchData)
            default:
                throw URLError(.unsupportedURL)
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
    func testQuarantinedEditDoesNotBlockLaterAuthoritativeServerUpsert() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "conflicted", expression: "resolved server snapshot")
        let server = makeCard(id: local.id, expression: "newer server edit")
        let localID = local.id
        insert(local, userID: 1, in: container)
        let quarantined = PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: local.id.uppercased(),
            payload: Data()
        )
        quarantined.lastError = "HTTP 409 [card_revision_conflict]: stale edit"
        container.mainContext.insert(quarantined)
        try container.mainContext.save()
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, localID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext
        )
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
            id: "local-id",
            syncId: "server-id",
            expression: "local edit",
            queueState: "review",
            masteryLevel: "guru"
        )
        let staleCanonical = makeCard(
            id: "server-id",
            expression: "stale server",
            queueState: "review",
            masteryLevel: "apprentice"
        )
        let server = makeCard(
            id: "server-id",
            expression: "fresh server",
            queueState: "learning",
            masteryLevel: "enlightened"
        )
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.isInActiveSession = false
        localRecord.queueIndex = 8
        let canonicalRecord = insert(staleCanonical, userID: 1, in: container)
        canonicalRecord.queueIndex = 2
        let preparedAt = Date(timeIntervalSince1970: 50)
        canonicalRecord.mediaPreparedAt = preparedAt
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: local.id,
            payload: Data()
        ))
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)
        var publishedCards = [local, staleCanonical]
        var publishedReconciler = StudyPublishedCardReconciler()

        _ = try await repository.pullChanges { changes in
            publishedReconciler.apply(changes, to: &publishedCards)
        }

        let storedRecords = try records(for: 1, in: container)
        let storedRecord = try XCTUnwrap(storedRecords.first)
        let storedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: storedRecord.payload
        )
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

    @MainActor
    func testServerUpsertRetainsPendingDuplicateTargetedThroughItsSyncAlias() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id",
            syncId: "server-id",
            expression: "local edit"
        )
        let pendingDuplicate = makeCard(
            id: "server-id",
            syncId: "pending-alias",
            expression: "pending duplicate"
        )
        let server = makeCard(id: "server-id", expression: "fresh server")
        let localRecord = insert(local, userID: 1, in: container)
        localRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let pendingRecord = insert(pendingDuplicate, userID: 1, in: container)
        pendingRecord.locallyUpdatedAt = nil
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: "pending-alias",
            payload: Data()
        ))
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
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
            id: "local-id",
            syncId: "server-id",
            expression: "local edit",
            audioURL: "https://example.com/local.mp3"
        )
        let staleCanonical = makeCard(
            id: "server-id",
            expression: "stale server",
            audioURL: "https://example.com/stale.mp3"
        )
        let server = makeCard(
            id: "server-id",
            expression: "fresh server",
            audioURL: "https://example.com/server.mp3"
        )
        let localRecord = insert(local, userID: 1, in: container)
        let canonicalRecord = insert(staleCanonical, userID: 1, in: container)
        canonicalRecord.mediaPreparedAt = Date(timeIntervalSince1970: 50)
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: local.id,
            payload: Data()
        ))
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        let storedRecord = try XCTUnwrap(storedRecords.first)
        let storedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: storedRecord.payload
        )
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertTrue(storedRecord === localRecord)
        XCTAssertEqual(storedCard.mediaURLs, local.mediaURLs)
        XCTAssertNil(storedRecord.mediaPreparedAt)
    }

    @MainActor
    func testServerUpsertTraversesAliasChainWithoutDuplicatingRetainedDirtySessionRow() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id",
            syncId: "bridge-id",
            expression: "newest local edit"
        )
        let bridge = makeCard(
            id: "bridge-id",
            syncId: "server-id",
            expression: "older local edit"
        )
        let staleCanonical = makeCard(id: "server-id", expression: "stale server")
        let server = makeCard(
            id: "server-id",
            expression: "fresh server",
            queueState: "learning",
            masteryLevel: "enlightened"
        )
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
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        let updatedLocal = try XCTUnwrap(storedRecords.first { $0.id == local.id })
        let updatedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: updatedLocal.payload
        )
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
            id: "a-reviewed-alias",
            syncId: "server-id",
            expression: "older reviewed copy",
            queueState: "learning",
            masteryLevel: "apprentice"
        )
        let reviewed = makeCard(
            id: "reviewed-alias",
            syncId: "server-id",
            expression: "reviewed copy",
            queueState: "review",
            masteryLevel: "enlightened"
        )
        let edited = makeCard(
            id: "edited-alias",
            syncId: "server-id",
            expression: "local edit",
            queueState: "learning",
            masteryLevel: "apprentice"
        )
        let server = makeCard(
            id: "server-id",
            expression: "fresh server",
            queueState: "relearning",
            masteryLevel: "guru"
        )
        let olderReviewedRecord = insert(olderReviewed, userID: 1, in: container)
        let reviewedRecord = insert(reviewed, userID: 1, in: container)
        let editedRecord = insert(edited, userID: 1, in: container)
        editedRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let olderReviewMutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: olderReviewed.id,
            payload: Data()
        )
        olderReviewMutation.createdAt = Date(timeIntervalSince1970: 100)
        container.mainContext.insert(olderReviewMutation)
        let latestReviewMutation = PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: reviewed.id,
            payload: Data()
        )
        latestReviewMutation.createdAt = Date(timeIntervalSince1970: 200)
        container.mainContext.insert(latestReviewMutation)
        try container.mainContext.save()
        let serverID = server.id
        let batchData = try Self.batchData([server])
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        let storedRecords = try records(for: 1, in: container)
        let storedEdited = try XCTUnwrap(storedRecords.first { $0 === editedRecord })
        let storedCard = try StorageCodec.decoder.decode(
            StudyCard.self,
            from: storedEdited.payload
        )
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
            id: "reviewed",
            expression: "local text",
            queueState: "review",
            masteryLevel: "enlightened"
        )
        let server = makeCard(
            id: local.id,
            expression: "server text",
            queueState: "learning",
            masteryLevel: "guru"
        )
        let serverID = server.id
        let batchData = try Self.batchData([server])
        insert(local, userID: 1, in: container)
        container.mainContext.insert(PendingMutation(
            kind: "review",
            userID: 1,
            resourceID: local.id,
            payload: Data()
        ))
        try container.mainContext.save()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
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
        container.mainContext.insert(PendingMutation(
            kind: "cardDelete",
            userID: 1,
            resourceID: serverID.uppercased(),
            payload: Data()
        ))
        try container.mainContext.save()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "update")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
    }

    @MainActor
    func testDeletionAndPendingChecksResolveLocalIDAndSyncIDInBothDirections() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let feedUsesSyncID = makeCard(
            id: "local-forward",
            syncId: "server-forward",
            expression: "forward"
        )
        let feedUsesLocalID = makeCard(
            id: "server-reverse",
            syncId: "local-reverse",
            expression: "reverse"
        )
        insert(feedUsesSyncID, userID: 1, in: container)
        insert(feedUsesLocalID, userID: 1, in: container)
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: feedUsesSyncID.id,
            payload: Data()
        ))
        container.mainContext.insert(PendingMutation(
            kind: "cardUpdate",
            userID: 1,
            resourceID: try XCTUnwrap(feedUsesLocalID.syncId),
            payload: Data()
        ))
        try container.mainContext.save()
        let forwardFeedID = try XCTUnwrap(feedUsesSyncID.syncId)
        let reverseFeedID = feedUsesLocalID.id
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            let isFirstPage = feedRequests.next() == 1
            return Self.response(data: Self.feedData(
                entries: [
                    (isFirstPage ? 1 : 3, forwardFeedID, "delete"),
                    (isFirstPage ? 2 : 4, reverseFeedID, "delete"),
                ],
                nextCheckpoint: isFirstPage ? 2 : 4,
                hasMore: false
            ))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(
            Set(try cards(for: 1, in: container).map(\.id)),
            Set([feedUsesSyncID.id, feedUsesLocalID.id])
        )
        for mutation in try container.mainContext.fetch(FetchDescriptor<PendingMutation>()) {
            container.mainContext.delete(mutation)
        }
        try container.mainContext.save()

        let deletionResult = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(
            deletionResult,
            .completed(deletedCardIdentifiers: [
                feedUsesSyncID.id,
                forwardFeedID,
                reverseFeedID,
                try XCTUnwrap(feedUsesLocalID.syncId),
            ])
        )
        XCTAssertEqual(try checkpoint(for: 1, in: container), 4)
    }

    @MainActor
    func testServerDeleteTraversesEntireAliasChain() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id",
            syncId: "bridge-id",
            expression: "local"
        )
        let bridge = makeCard(
            id: "bridge-id",
            syncId: "server-id",
            expression: "bridge"
        )
        insert(local, userID: 1, in: container)
        insert(bridge, userID: 1, in: container)
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Self.feedData(
                entries: [(1, "server-id", "delete")],
                nextCheckpoint: 1,
                hasMore: false
            ))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertTrue(try records(for: 1, in: container).isEmpty)
        XCTAssertEqual(
            result,
            .completed(deletedCardIdentifiers: ["local-id", "bridge-id", "server-id"])
        )
    }

    @MainActor
    func testAliasLookupNeverCrossesAccountBoundary() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let userOneCard = makeCard(
            id: "user-one-local",
            syncId: "shared-server-id",
            expression: "user one"
        )
        let userTwoCard = makeCard(
            id: "user-two-local",
            syncId: "shared-server-id",
            expression: "user two"
        )
        insert(userOneCard, userID: 1, in: container)
        insert(userTwoCard, userID: 2, in: container)
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Self.feedData(
                entries: [(1, "shared-server-id", "delete")],
                nextCheckpoint: 1,
                hasMore: false
            ))
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
        let card = makeCard(
            id: "MixedCase-ID",
            syncId: "different-server-alias",
            expression: "mixed case"
        )
        insert(card, userID: 1, in: container)
        try container.mainContext.save()
        let cardID = card.id
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Self.feedData(
                entries: [(1, cardID, "delete")],
                nextCheckpoint: 1,
                hasMore: false
            ))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(
            result,
            .completed(deletedCardIdentifiers: [
                "mixedcase-id",
                "different-server-alias",
            ])
        )
    }

    @MainActor
    func testMultiPageFeedQueriesOnlyMatchingAliasRecords() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let libraryCards = (0..<10).map {
            makeCard(
                id: "local-\($0)",
                syncId: "server-\($0)",
                expression: "card \($0)"
            )
        }
        for card in libraryCards {
            insert(card, userID: 1, in: container)
        }
        try container.mainContext.save()
        let firstSyncID = try XCTUnwrap(libraryCards[0].syncId)
        let secondSyncID = try XCTUnwrap(libraryCards[1].syncId)
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            let isFirstPage = feedRequests.next() == 1
            return Self.response(data: Self.feedData(
                entries: [(
                    isFirstPage ? 1 : 2,
                    isFirstPage ? firstSyncID : secondSyncID,
                    "delete"
                )],
                nextCheckpoint: isFirstPage ? 1 : 2,
                hasMore: isFirstPage
            ))
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            onIndexingRecord: { _ = indexedRecords.next() }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 2)
        XCTAssertEqual(try cards(for: 1, in: container).count, libraryCards.count - 2)
    }

    @MainActor
    func testSequentialUpsertPullsReuseUnchangedAliasIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let libraryCards = (0..<10).map {
            makeCard(id: "card-\($0)", expression: "card \($0)")
        }
        for card in libraryCards {
            insert(card, userID: 1, in: container)
        }
        try container.mainContext.save()
        let serverCard = makeCard(id: libraryCards[0].id, expression: "fresh server")
        let serverCardID = serverCard.id
        let batchData = try Self.batchData([serverCard])
        let feedRequests = LockedCounter()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                let checkpoint = feedRequests.next()
                return Self.response(data: Self.feedData(
                    entries: [(Int64(checkpoint), serverCardID, "update")],
                    nextCheckpoint: Int64(checkpoint),
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            onIndexingRecord: { _ = indexedRecords.next() }
        )
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
        let libraryCards = (0..<10).map {
            makeCard(id: "card-\($0)", expression: "card \($0)")
        }
        for card in libraryCards {
            insert(card, userID: 1, in: container)
        }
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
                return Self.response(data: Self.feedData(
                    entries: [(
                        Int64(checkpoint),
                        checkpoint == 1 ? firstServerCardID : insertedServerCardID,
                        "update"
                    )],
                    nextCheckpoint: Int64(checkpoint),
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                let ids = try Self.batchIDs(in: request)
                return Self.response(
                    data: ids == [firstServerCardID] ? firstData : insertedData
                )
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            onIndexingRecord: { _ = indexedRecords.next() }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()
        insert(
            makeCard(id: insertedServerCardID, expression: "inserted local"),
            userID: 1,
            in: container
        )
        try container.mainContext.save()
        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 2)
        let inserted = try XCTUnwrap(
            cards(for: 1, in: container).first { $0.id == insertedServerCardID }
        )
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
                return Self.response(data: Self.feedData(
                    entries: [(Int64(checkpoint), serverCardID, "update")],
                    nextCheckpoint: Int64(checkpoint),
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                return Self.response(data: batchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            onIndexingRecord: { _ = indexedRecords.next() }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()
        container.mainContext.insert(LocalKnownKanjiSnapshot(
            userID: 1,
            payload: Data("unrelated".utf8)
        ))
        try container.mainContext.save()
        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 1)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 2)
    }

    @MainActor
    func testEmptyFeedDoesNotBuildAliasIndex() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        for index in 0..<10 {
            insert(
                makeCard(id: "card-\(index)", expression: "card \(index)"),
                userID: 1,
                in: container
            )
        }
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Self.feedData(
                entries: [],
                nextCheckpoint: 0,
                hasMore: false
            ))
        }
        let indexedRecords = LockedCounter()
        let repository = CardSyncFeedRepository(
            api: client,
            context: container.mainContext,
            onIndexingRecord: { _ = indexedRecords.next() }
        )
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        XCTAssertEqual(indexedRecords.current, 0)
        XCTAssertEqual(try cards(for: 1, in: container).count, 10)
    }

    @MainActor
    func testDirtyCardIgnoresTombstoneAndIsNotReportedAsDeleted() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dirty = makeCard(
            id: "local-dirty",
            syncId: "server-dirty",
            expression: "local edit"
        )
        let record = insert(dirty, userID: 1, in: container)
        record.locallyUpdatedAt = .now
        try container.mainContext.save()
        let feedID = try XCTUnwrap(dirty.syncId)
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(data: Self.feedData(
                entries: [(1, feedID, "delete")],
                nextCheckpoint: 1,
                hasMore: false
            ))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertEqual(result, .completed(deletedCardIdentifiers: []))
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [dirty.id])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 1)
    }

    @MainActor
    func testStaleResponseAfterAccountSwitchCannotWriteOrAdvanceCheckpoint() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let server = makeCard(id: "stale", expression: "old account")
        let serverID = server.id
        let serverBatchData = try Self.batchData([server])
        let gate = LockedRequestGate()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "create")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                gate.markStarted()
                gate.waitForRelease()
                return Self.response(data: serverBatchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let pull = Task { try await repository.pullChanges() }
        await waitUntil { gate.hasStarted }
        repository.activate(userID: 2)
        gate.release()

        let result = try await pull.value
        XCTAssertEqual(result, .discardedStaleResponse)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertTrue(try cards(for: 2, in: container).isEmpty)
    }

    @MainActor
    func testSameAccountReactivationInvalidatesAnOlderResponseGeneration() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let server = makeCard(id: "stale", expression: "old activation")
        let serverID = server.id
        let serverBatchData = try Self.batchData([server])
        let gate = LockedRequestGate()
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed":
                return Self.response(data: Self.feedData(
                    entries: [(1, serverID, "create")],
                    nextCheckpoint: 1,
                    hasMore: false
                ))
            case "/api/study/cards/batch":
                gate.markStarted()
                gate.waitForRelease()
                return Self.response(data: serverBatchData)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let pull = Task { try await repository.pullChanges() }
        await waitUntil { gate.hasStarted }
        repository.deactivate()
        repository.activate(userID: 1)
        gate.release()

        let result = try await pull.value
        XCTAssertEqual(result, .discardedStaleResponse)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
    }

    @MainActor
    func testExpiredCheckpointResetPreservesDirtyRowsAndClearsServerBackedRowsAtomically() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let clean = makeCard(id: "clean", expression: "server backed")
        let dirty = makeCard(id: "dirty", expression: "local edit")
        insert(clean, userID: 1, in: container)
        let dirtyRecord = insert(dirty, userID: 1, in: container)
        dirtyRecord.locallyUpdatedAt = .now
        container.mainContext.insert(LocalSyncState(userID: 1, cardCheckpoint: 99))
        try container.mainContext.save()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/sync/feed")
            return Self.response(
                statusCode: 409,
                data: Data(#"{"message":"Checkpoint expired"}"#.utf8)
            )
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertEqual(result, .checkpointReset(deletedCardIdentifiers: [clean.id]))
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [dirty.id])
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

    @MainActor
    @discardableResult
    private func insert(
        _ card: StudyCard,
        userID: Int,
        in container: ModelContainer
    ) -> LocalCardRecord {
        let record = LocalCardRecord(
            card: card,
            userID: userID,
            queueIndex: 0,
            payload: try! StorageCodec.encoder.encode(card)
        )
        container.mainContext.insert(record)
        return record
    }

    @MainActor
    private func checkpoint(for userID: Int, in container: ModelContainer) throws -> Int64? {
        try container.mainContext.fetch(FetchDescriptor<LocalSyncState>())
            .first(where: { $0.userID == userID })?
            .cardCheckpoint
    }

    @MainActor
    private func records(for userID: Int, in container: ModelContainer) throws -> [LocalCardRecord] {
        try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
            .filter { $0.userID == userID }
    }

    @MainActor
    private func cards(for userID: Int, in container: ModelContainer) throws -> [StudyCard] {
        try records(for: userID, in: container)
            .map { try StorageCodec.decoder.decode(StudyCard.self, from: $0.payload) }
            .sorted { $0.id < $1.id }
    }

    @MainActor
    private func makeCard(
        id: String,
        syncId: String? = nil,
        expression: String,
        audioURL: String? = nil,
        queueState: String = "review",
        masteryLevel: String? = nil,
        variantGroupID: String? = nil,
        variantStatus: String? = nil
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let audioURL {
            prompt["audioUrl"] = .string(audioURL)
        }
        return StudyCard(
            id: id,
            syncId: syncId,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(prompt),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: nil,
                introducedAt: nil,
                failedAt: nil,
                queueState: queueState,
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            masteryLevel: masteryLevel,
            variantGroupId: variantGroupID,
            variantStatus: variantStatus,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }

    private static func feedData(
        entries: [(Int64, String, String)],
        nextCheckpoint: Int64,
        hasMore: Bool
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "data": entries.map { checkpoint, resourceID, operation in
                [
                    "checkpoint": checkpoint,
                    "resource_id": resourceID,
                    "operation": operation,
                ] as [String: Any]
            },
            "meta": [
                "next_checkpoint": nextCheckpoint,
                "has_more": hasMore,
            ],
        ])
    }

    @MainActor
    private static func batchData(
        _ cards: [StudyCard],
        omittingProgressionMetadata: Bool = false
    ) throws -> Data {
        let values = try cards.map { card in
            var value = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: StorageCodec.encoder.encode(card)
                ) as? [String: Any]
            )
            if omittingProgressionMetadata {
                value.removeValue(forKey: "variantGroupId")
                value.removeValue(forKey: "variantStatus")
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: ["cards": values])
    }

    private static func batchIDs(in request: URLRequest) throws -> [String] {
        let body = try XCTUnwrap(request.httpBody ?? requestBody(request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: [String]]
        )
        return try XCTUnwrap(object["ids"])
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    private static func response(
        statusCode: Int = 200,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "https://learning-os.example")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct InjectedPageFailure: Error {}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        // Expected.
    }
}
