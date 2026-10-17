import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension CardSyncFeedRepositoryTests {
    @MainActor
    func testRetainedDirtyAliasBecomesInactiveBeforeLaterInsertInSamePage() async throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let (survivor, retained) = try prepareDirtyAliases(in: container)
        let batch = try Self.batchData([
            makeCard(id: "server", expression: "Server"), makeCard(id: "next", expression: "Next"),
        ])
        let feed = Self.feedData(entries: [
            (1, "server", "update"), (2, "server", "update"), (3, "next", "create"),
        ], nextCheckpoint: 3, hasMore: false)
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/sync/feed": return Self.response(data: feed)
            case "/api/study/cards/batch": return Self.response(data: batch)
            default: throw URLError(.unsupportedURL)
            }
        }
        let repository = CardSyncFeedRepository(api: client, context: container.mainContext)
        repository.activate(userID: 1)

        _ = try await repository.pullChanges()

        try assertRetainedDirtyAliasConsolidation(in: container, survivor: survivor, retained: retained)
    }

    @MainActor
    private func prepareDirtyAliases(in container: ModelContainer) throws -> (LocalCardRecord, LocalCardRecord) {
        let survivor = insert(
            makeCard(id: "local-survivor", syncId: "server", expression: "Selected local edit"),
            userID: 1, in: container
        )
        survivor.queueIndex = 0
        survivor.locallyUpdatedAt = Date(timeIntervalSince1970: 200)
        let retained = insert(
            makeCard(id: "local-retained", syncId: "server", expression: "Retained local edit"),
            userID: 1, in: container
        )
        retained.queueIndex = 2
        retained.locallyUpdatedAt = Date(timeIntervalSince1970: 100)
        let unrelated = insert(makeCard(id: "unrelated", expression: "Unrelated"), userID: 1, in: container)
        unrelated.queueIndex = 1
        try container.mainContext.save()
        return (survivor, retained)
    }

    @MainActor
    private func assertRetainedDirtyAliasConsolidation(
        in container: ModelContainer, survivor: LocalCardRecord, retained: LocalCardRecord
    ) throws {
        let stored = try records(for: 1, in: container)
        XCTAssertEqual(Set(stored.map(\.id)), ["local-survivor", "local-retained", "unrelated", "next"])
        XCTAssertTrue(stored.contains { $0 === retained }, "Dirty aliases must remain persisted.")
        XCTAssertFalse(retained.isInActiveSession, "Retained aliases leave the active queue during consolidation.")
        XCTAssertEqual(retained.locallyUpdatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            try StorageCodec.decoder.decode(StudyCard.self, from: retained.payload).promptText,
            "Retained local edit"
        )
        XCTAssertTrue(survivor.isInActiveSession)
        XCTAssertEqual(survivor.queueIndex, 0)
        XCTAssertEqual(stored.first { $0.id == "next" }?.queueIndex, 2)
        XCTAssertEqual(stored.filter(\.isInActiveSession).map(\.queueIndex).sorted(), [0, 1, 2])
        XCTAssertEqual(try checkpoint(for: 1, in: container), 3)
    }
}
