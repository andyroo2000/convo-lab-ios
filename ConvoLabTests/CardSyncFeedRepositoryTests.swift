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

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(requestedCheckpoints.values, ["4", "5"])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 6)
        XCTAssertEqual(Set(try cards(for: 1, in: container).map(\.id)), ["card-1", "card-2"])
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

        _ = try await repository.pullChanges()

        let stored = try cards(for: 1, in: container)
        XCTAssertEqual(stored.map(\.id), [restored.id])
        XCTAssertEqual(stored.first?.promptText, "restored-server")
        XCTAssertEqual(try checkpoint(for: 1, in: container), 4)
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
        let local = makeCard(id: "dirty", expression: "local edit", queueState: "review")
        let server = makeCard(id: local.id, expression: "server edit", queueState: "learning")
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
    func testPendingReviewPreservesSchedulingStateWithoutHidingServerContent() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(id: "reviewed", expression: "local text", queueState: "review")
        let server = makeCard(id: local.id, expression: "server text", queueState: "learning")
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

        _ = try await repository.pullChanges()

        XCTAssertTrue(try cards(for: 1, in: container).isEmpty)
        XCTAssertEqual(try checkpoint(for: 1, in: container), 4)
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

        XCTAssertEqual(result, .checkpointReset)
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
        queueState: String = "review"
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncId,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(expression)]),
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
    private static func batchData(_ cards: [StudyCard]) throws -> Data {
        let values = try cards.map {
            try JSONSerialization.jsonObject(with: StorageCodec.encoder.encode($0))
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
