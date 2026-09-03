import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
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
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "create")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch":
                gate.markStarted()
                gate.waitForRelease()
                return Self.response(data: serverBatchData)
            default: throw URLError(.unsupportedURL)
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
                return Self.response(
                    data: Self.feedData(entries: [(1, serverID, "create")], nextCheckpoint: 1, hasMore: false))
            case "/api/study/cards/batch":
                gate.markStarted()
                gate.waitForRelease()
                return Self.response(data: serverBatchData)
            default: throw URLError(.unsupportedURL)
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
            return Self.response(statusCode: 409, data: Data(#"{"message":"Checkpoint expired"}"#.utf8))
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        let result = try await repository.pullChanges()

        XCTAssertEqual(result, .checkpointReset(deletedCardIdentifiers: [clean.id]))
        XCTAssertEqual(try checkpoint(for: 1, in: container), 0)
        XCTAssertEqual(try cards(for: 1, in: container).map(\.id), [dirty.id])
    }
}
