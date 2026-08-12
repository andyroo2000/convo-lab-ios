import XCTest
import SwiftData
@testable import ConvoLab

final class StudyCardLocalRepositoryTests: XCTestCase {
    @MainActor
    func testActiveSessionRefreshPreservesDirtyContentButUpdatesQueueMetadata() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localDirty = makeCard(
            id: "local-dirty",
            syncId: "server-dirty",
            expression: "local dirty"
        )
        let serverDirty = makeCard(id: "SERVER-DIRTY", expression: "server dirty")
        let stale = makeCard(id: "stale", expression: "stale")
        let otherUser = makeCard(id: "other-user", expression: "other")
        let dirtyRecord = insert(
            localDirty,
            userID: 1,
            queueIndex: 42,
            locallyUpdatedAt: .now,
            in: container
        )
        let staleRecord = insert(stale, userID: 1, queueIndex: 0, in: container)
        let otherRecord = insert(otherUser, userID: 2, queueIndex: 7, in: container)
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)
        let inserted = makeCard(id: "inserted", expression: "inserted")

        try repository.replaceActiveSession(
            with: [inserted, serverDirty],
            userID: 1
        )

        XCTAssertTrue(dirtyRecord.isInActiveSession)
        XCTAssertEqual(dirtyRecord.queueIndex, 1)
        XCTAssertEqual(try decode(dirtyRecord).promptText, localDirty.promptText)
        XCTAssertNil(try record(id: "SERVER-DIRTY", userID: 1, in: container))
        XCTAssertFalse(staleRecord.isInActiveSession)
        XCTAssertTrue(otherRecord.isInActiveSession)
        XCTAssertEqual(otherRecord.queueIndex, 7)
        let insertedRecord = try XCTUnwrap(record(id: inserted.id, userID: 1, in: container))
        XCTAssertTrue(insertedRecord.isInActiveSession)
        XCTAssertEqual(insertedRecord.queueIndex, 0)
    }

    @MainActor
    func testReserveMergeMatchesCaseInsensitivelyAndKeepsSessionMembership() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let dirty = makeCard(id: "LOCAL-ID", expression: "local dirty")
        let dirtyRecord = insert(
            dirty,
            userID: 1,
            queueIndex: 30,
            locallyUpdatedAt: .now,
            in: container
        )
        let clean = makeCard(id: "clean", expression: "old clean")
        let cleanRecord = insert(clean, userID: 1, queueIndex: 31, in: container)
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)
        let serverDirty = makeCard(id: "local-id", expression: "server dirty")
        let serverClean = makeCard(id: clean.id, expression: "new clean")
        let inserted = makeCard(id: "reserve-only", expression: "reserve")

        try repository.mergeOfflineReserve(
            [serverDirty, serverClean, inserted],
            userID: 1
        )

        XCTAssertTrue(dirtyRecord.isInActiveSession)
        XCTAssertEqual(dirtyRecord.queueIndex, 0)
        XCTAssertEqual(try decode(dirtyRecord).promptText, dirty.promptText)
        XCTAssertEqual(cleanRecord.queueIndex, 1)
        XCTAssertEqual(try decode(cleanRecord).promptText, serverClean.promptText)
        let insertedRecord = try XCTUnwrap(record(id: inserted.id, userID: 1, in: container))
        XCTAssertFalse(insertedRecord.isInActiveSession)
        XCTAssertEqual(insertedRecord.queueIndex, 2)
    }

    @MainActor
    func testReserveMergeUpdatesExistingLocalServerAliasWithoutPersistingDuplicate() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let local = makeCard(
            id: "local-id",
            syncId: "server-id",
            expression: "local"
        )
        let localRecord = insert(local, userID: 1, queueIndex: 10, in: container)
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)
        let canonical = makeCard(id: "SERVER-ID", expression: "server")

        try repository.mergeOfflineReserve([canonical], userID: 1)

        let records = try container.mainContext.fetch(FetchDescriptor<LocalCardRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records.first === localRecord)
        XCTAssertEqual(localRecord.id, "local-id")
        XCTAssertEqual(localRecord.queueIndex, 0)
        let merged = try decode(localRecord)
        XCTAssertEqual(merged.id, "local-id")
        XCTAssertEqual(merged.reviewCardID, "SERVER-ID")
        XCTAssertEqual(merged.promptText, "server")
    }

    @MainActor
    func testPreparedMediaUpdatesAreAccountScopedAndCanClearOmittedCards() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let cached = makeCard(
            id: "local-cached",
            syncId: "server-cached",
            expression: "cached",
            mediaURL: "/api/study/media/cached"
        )
        let canonicalCached = makeCard(
            id: "SERVER-CACHED",
            expression: "cached",
            mediaURL: "/api/study/media/cached"
        )
        let missing = makeCard(
            id: "missing",
            expression: "missing",
            mediaURL: "/api/study/media/missing"
        )
        let textOnly = makeCard(id: "text", expression: "text")
        let omitted = makeCard(id: "omitted", expression: "omitted")
        let otherUser = makeCard(id: "other", expression: "other")
        let records = [cached, missing, textOnly, omitted].map {
            insert($0, userID: 1, queueIndex: 0, mediaPreparedAt: .now, in: container)
        }
        let otherRecord = insert(
            otherUser,
            userID: 2,
            queueIndex: 0,
            mediaPreparedAt: .now,
            in: container
        )
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)
        let cachedURL = try XCTUnwrap(cached.mediaURLs.first)

        try repository.updateMediaPreparedState(
            for: [canonicalCached, missing, textOnly],
            userID: 1,
            cachedKeys: [MediaCache.stableCacheKey(for: cachedURL)],
            clearingOtherRecords: true
        )

        XCTAssertNotNil(records[0].mediaPreparedAt)
        XCTAssertNil(records[1].mediaPreparedAt)
        XCTAssertNotNil(records[2].mediaPreparedAt)
        XCTAssertNil(records[3].mediaPreparedAt)
        XCTAssertNotNil(otherRecord.mediaPreparedAt)
    }

    @MainActor
    func testLoadsAreAccountScopedOrderedAndSkipCorruptPayloads() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let older = makeCard(id: "older", expression: "older")
        let newer = makeCard(id: "newer", expression: "newer")
        let olderRecord = insert(older, userID: 1, queueIndex: 1, in: container)
        olderRecord.serverUpdatedAt = Date(timeIntervalSince1970: 10)
        let newerRecord = insert(newer, userID: 1, queueIndex: 0, in: container)
        newerRecord.serverUpdatedAt = Date(timeIntervalSince1970: 20)
        let corrupt = insert(
            makeCard(id: "corrupt", expression: "corrupt"),
            userID: 1,
            queueIndex: 2,
            in: container
        )
        corrupt.payload = Data("not-json".utf8)
        _ = insert(makeCard(id: "other", expression: "other"), userID: 2, queueIndex: 0, in: container)
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)

        XCTAssertEqual(try repository.activeCards(userID: 1).map(\.id), [newer.id, older.id])
        XCTAssertEqual(try repository.libraryCards(userID: 1).map(\.id), [newer.id, older.id])
    }

    @MainActor
    func testIndexedLookupResolvesAliasesWithinOneAccountDeterministically() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let localAlias = makeCard(
            id: "Mixed-Local-ID",
            syncId: "server-id",
            expression: "local alias"
        )
        let localRecord = insert(localAlias, userID: 1, queueIndex: 0, in: container)
        let canonical = makeCard(id: "SERVER-ID", expression: "canonical")
        let canonicalRecord = insert(canonical, userID: 1, queueIndex: 1, in: container)
        let otherUserRecord = insert(
            makeCard(
                id: "other-user-local",
                syncId: "server-id",
                expression: "other user"
            ),
            userID: 2,
            queueIndex: 0,
            in: container
        )
        _ = insert(
            makeCard(id: "z-alias", syncId: "shared-server-id", expression: "clean"),
            userID: 3,
            queueIndex: 0,
            in: container
        )
        let dirtyAliasRecord = insert(
            makeCard(id: "a-alias", syncId: "shared-server-id", expression: "dirty"),
            userID: 3,
            queueIndex: 1,
            in: container
        )
        dirtyAliasRecord.locallyUpdatedAt = Date(timeIntervalSince1970: 2)
        let cardIDAliasRecord = insert(
            makeCard(id: "card-id-alias", syncId: "searched-id", expression: "ID alias"),
            userID: 4,
            queueIndex: 0,
            in: container
        )
        _ = insert(
            makeCard(
                id: "sync-id-alias",
                syncId: "searched-sync-id",
                expression: "sync ID alias"
            ),
            userID: 4,
            queueIndex: 1,
            in: container
        )
        _ = insert(
            makeCard(id: "case-id", expression: "lowercase duplicate"),
            userID: 5,
            queueIndex: 0,
            in: container
        )
        let exactCaseRecord = insert(
            makeCard(id: "CASE-ID", expression: "exact-case duplicate"),
            userID: 5,
            queueIndex: 1,
            in: container
        )
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)

        XCTAssertTrue(try repository.record(matching: canonical, userID: 1) === canonicalRecord)
        let staleLocalSnapshot = makeCard(
            id: localAlias.id,
            syncId: canonical.id,
            expression: "stale"
        )
        XCTAssertTrue(
            try repository.record(matching: staleLocalSnapshot, userID: 1) === localRecord
        )
        XCTAssertTrue(
            try repository.record(matching: canonical, userID: 2) === otherUserRecord
        )
        let unresolvedCanonical = makeCard(
            id: "not-yet-stored",
            syncId: "shared-server-id",
            expression: "incoming"
        )
        XCTAssertTrue(
            try repository.record(matching: unresolvedCanonical, userID: 3) === dirtyAliasRecord
        )
        let divergentSnapshot = makeCard(
            id: "searched-id",
            syncId: "searched-sync-id",
            expression: "divergent"
        )
        XCTAssertTrue(
            try repository.record(matching: divergentSnapshot, userID: 4) === cardIDAliasRecord
        )
        XCTAssertTrue(
            try repository.record(
                matching: makeCard(id: "CASE-ID", expression: "incoming"),
                userID: 5
            ) === exactCaseRecord
        )
    }

    @MainActor
    private func insert(
        _ card: StudyCard,
        userID: Int,
        queueIndex: Int,
        locallyUpdatedAt: Date? = nil,
        mediaPreparedAt: Date? = nil,
        in container: ModelContainer
    ) -> LocalCardRecord {
        let record = LocalCardRecord(
            card: card,
            userID: userID,
            queueIndex: queueIndex,
            payload: try! StorageCodec.encoder.encode(card)
        )
        record.locallyUpdatedAt = locallyUpdatedAt
        record.mediaPreparedAt = mediaPreparedAt
        container.mainContext.insert(record)
        return record
    }

    @MainActor
    private func record(
        id: String,
        userID: Int,
        in container: ModelContainer
    ) throws -> LocalCardRecord? {
        try container.mainContext.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID && $0.id == id }
            )
        ).first
    }

    @MainActor
    private func decode(_ record: LocalCardRecord) throws -> StudyCard {
        try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }

    @MainActor
    private func makeCard(
        id: String,
        syncId: String? = nil,
        expression: String,
        mediaURL: String? = nil
    ) -> StudyCard {
        var prompt: [String: JSONValue] = ["cueText": .string(expression)]
        if let mediaURL {
            prompt["cueAudio"] = .object(["url": .string(mediaURL)])
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
                queueState: "review",
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }
}
