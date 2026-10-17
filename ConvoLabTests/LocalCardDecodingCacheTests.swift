import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

final class LocalCardDecodingCacheTests: XCTestCase {
    @MainActor
    func testDecodeUsesPayloadInsteadOfConstructorProjection() throws {
        let constructor = makeCard(text: "Constructor")
        let payload = try StorageCodec.encoder.encode(makeCard(text: "Persisted"))
        let record = LocalCardRecord(card: constructor, userID: 1, queueIndex: 0, payload: payload)

        XCTAssertEqual(try StudyCardDecodingCache().card(from: record).promptText, "Persisted")
    }

    @MainActor
    func testDirectPayloadChangeInvalidatesAlreadyDecodedCard() throws {
        let record = try makeRecord(text: "Before")
        let (cache, calls) = makeCountingCache()
        XCTAssertEqual(try cache.card(from: record).promptText, "Before")
        let originalSize = record.payload.count

        record.payload = try StorageCodec.encoder.encode(makeCard(text: "After!"))

        XCTAssertEqual(record.payload.count, originalSize)
        XCTAssertEqual(try cache.card(from: record).promptText, "After!")
        XCTAssertEqual(try cache.card(from: record).promptText, "After!")
        XCTAssertEqual(calls.values.count, 2)
    }

    @MainActor
    func testCorruptPayloadNeverReturnsPreviousCachedValueAndCanRecover() throws {
        let record = try makeRecord(text: "Before")
        let (cache, calls) = makeCountingCache()
        let originalPayload = record.payload
        _ = try cache.card(from: record)
        record.payload = Data("not JSON".utf8)

        XCTAssertThrowsError(try cache.card(from: record))
        XCTAssertThrowsError(try cache.card(from: record))
        record.replacePayload(encoded: originalPayload)
        XCTAssertEqual(try cache.card(from: record).promptText, "Before")
        XCTAssertEqual(calls.values.count, 4, "Failed decoding must evict the previous value")
    }

    @MainActor
    func testRepositoryReloadAfterRollbackDoesNotReuseUnsavedCachedValue() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let record = try makeRecord(text: "Saved")
        let cache = StudyCardDecodingCache()
        container.mainContext.insert(record)
        try container.mainContext.save()
        _ = try cache.card(from: record)
        XCTAssertFalse(container.mainContext.hasChanges, "Reading the cache must not dirty persistent state")
        record.replacePayload(encoded: try StorageCodec.encoder.encode(makeCard(text: "Unsaved")))
        XCTAssertEqual(try cache.card(from: record).promptText, "Unsaved")

        container.mainContext.rollback()

        // SwiftData invalidates the registered instance on rollback; this old
        // reference still contains Unsaved bytes. Production reads re-fetch rows.
        XCTAssertEqual(try StorageCodec.decoder.decode(StudyCard.self, from: record.payload).promptText, "Unsaved")
        let restored = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LocalCardRecord>()).first)
        XCTAssertEqual(try cache.card(from: restored).promptText, "Saved")
        let repository = StudyCardLocalRepository(context: container.mainContext, decodingCache: cache)
        XCTAssertEqual(try repository.libraryCards(userID: 1).map(\.promptText), ["Saved"])
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    @MainActor
    func testAccountsWithSameCardIdentifierDoNotShareDecodedValues() throws {
        let container = try Persistence.makeContainer(inMemory: true)
        let first = try makeRecord(text: "First account", userID: 1)
        let second = try makeRecord(text: "Second account", userID: 2)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        let repository = StudyCardLocalRepository(context: container.mainContext)
        XCTAssertEqual(try repository.libraryCards(userID: 1).map(\.promptText), ["First account"])
        XCTAssertEqual(try repository.libraryCards(userID: 2).map(\.promptText), ["Second account"])

        second.payload = try StorageCodec.encoder.encode(makeCard(text: "Changed second"))

        XCTAssertEqual(try repository.activeCards(userID: 1).map(\.promptText), ["First account"])
        XCTAssertEqual(try repository.activeCards(userID: 2).map(\.promptText), ["Changed second"])
    }

    @MainActor
    func testSessionClearingOnlyDirtiesPreviouslyActiveRecords() throws {
        let active = try makeRecord(text: "Active", id: "active")
        let container = try makeSeededContainer(including: active)
        let repository = StudyCardLocalRepository(context: container.mainContext)

        let counts = try changedRecordCounts(in: container.mainContext) {
            try repository.replaceActiveSession(with: [], userID: 1)
        }

        XCTAssertEqual(counts, ["1"])
        XCTAssertFalse(active.isInActiveSession)
    }

    @MainActor
    func testMediaClearingOnlyDirtiesRecordsWithPreparedMedia() throws {
        let prepared = try makeRecord(text: "Prepared", id: "prepared")
        prepared.mediaPreparedAt = .now
        let container = try makeSeededContainer(including: prepared)
        let repository = StudyCardLocalRepository(context: container.mainContext)

        let counts = try changedRecordCounts(in: container.mainContext) {
            try repository.updateMediaPreparedState(for: [], userID: 1, cachedKeys: [], clearingOtherRecords: true)
        }

        XCTAssertEqual(counts, ["1"])
        XCTAssertNil(prepared.mediaPreparedAt)
    }

    @MainActor
    func testExactPayloadIsDecodedOnceAcrossDistinctModelInstances() throws {
        let (cache, calls) = makeCountingCache()
        let first = try makeRecord(text: "Unchanged")
        let second = try makeRecord(text: "Unchanged")
        second.payload = first.payload
        XCTAssertFalse(first === second)

        XCTAssertEqual(try cache.card(from: first).promptText, "Unchanged")
        XCTAssertEqual(try cache.card(from: second).promptText, "Unchanged")

        XCTAssertEqual(calls.values.count, 1)
    }

    @MainActor
    func testAccountSwitchEvictsPreviousAccountEvenForIdenticalBytes() throws {
        let (cache, calls) = makeCountingCache()
        let first = try makeRecord(text: "Shared text", userID: 1)
        let second = try makeRecord(text: "Shared text", userID: 2)
        second.payload = first.payload
        XCTAssertEqual(first.payload, second.payload)

        _ = try cache.card(from: first)
        _ = try cache.card(from: second)
        _ = try cache.card(from: first)

        XCTAssertEqual(calls.values.count, 3)
    }

    @MainActor
    func testFullLibraryReadPrunesDeletedCachedRecords() throws {
        let fixture = try makeRepositoryFixture()
        _ = try fixture.repository.libraryCards(userID: 1)
        let originalPayload = fixture.record.payload
        fixture.container.mainContext.delete(fixture.record)
        try fixture.container.mainContext.save()
        XCTAssertTrue(try fixture.repository.libraryCards(userID: 1).isEmpty)
        let replacement = try makeRecord(text: "Stored")
        replacement.payload = originalPayload
        fixture.container.mainContext.insert(replacement)
        try fixture.container.mainContext.save()

        XCTAssertEqual(try fixture.repository.libraryCards(userID: 1).map(\.promptText), ["Stored"])
        XCTAssertEqual(fixture.calls.values.count, 2, "A deleted ID must not retain its cached value")
    }

    @MainActor
    func testEmptyAccountReadClearsPreviousAccountCache() throws {
        let fixture = try makeRepositoryFixture()
        _ = try fixture.repository.libraryCards(userID: 1)

        XCTAssertTrue(try fixture.repository.activeCards(userID: 2).isEmpty)
        _ = try fixture.repository.libraryCards(userID: 1)

        XCTAssertEqual(fixture.calls.values.count, 2)
    }

    @MainActor
    func testRepositoryCopySharesCacheAndExplicitClearForcesDecode() throws {
        let fixture = try makeRepositoryFixture()
        let copiedRepository = fixture.repository
        _ = try fixture.repository.libraryCards(userID: 1)
        _ = try copiedRepository.activeCards(userID: 1)
        XCTAssertEqual(fixture.calls.values.count, 1)

        copiedRepository.clearDecodedCache()
        _ = try fixture.repository.libraryCards(userID: 1)

        XCTAssertEqual(fixture.calls.values.count, 2)
    }

    @MainActor
    func testOfflineReconcilerReusesRepositoryDecodingCache() async throws {
        let fixture = try makeRepositoryFixture()
        let cards = try fixture.repository.libraryCards(userID: 1)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = APIClient(baseURL: URL(string: "https://cache-test.invalid")!, session: session)
        let reconciler = StudyOfflineCardReconciler(
            api: api, context: fixture.container.mainContext, repository: fixture.repository
        )

        try await reconciler.reconcile(
            confirmedCards: cards, at: .now, userID: 1,
            isCurrent: { true }, didReconcile: { _ in XCTFail("No repair is required") }
        )

        XCTAssertEqual(fixture.calls.values.count, 1)
    }

    @MainActor
    private func makeCountingCache() -> (StudyCardDecodingCache, LockedRequestPaths) {
        let calls = LockedRequestPaths()
        let cache = StudyCardDecodingCache { payload in
            calls.append("decode")
            return try StorageCodec.decoder.decode(StudyCard.self, from: payload)
        }
        return (cache, calls)
    }

    @MainActor
    private func makeRepositoryFixture() throws -> (
        container: ModelContainer, record: LocalCardRecord,
        repository: StudyCardLocalRepository, calls: LockedRequestPaths
    ) {
        let container = try Persistence.makeContainer(inMemory: true)
        let record = try makeRecord(text: "Stored")
        container.mainContext.insert(record)
        try container.mainContext.save()
        let (cache, calls) = makeCountingCache()
        let repository = StudyCardLocalRepository(context: container.mainContext, decodingCache: cache)
        return (container, record, repository, calls)
    }

    @MainActor
    private func changedRecordCounts(in context: ModelContext, operation: () throws -> Void) rethrows -> [String] {
        let counts = LockedRequestPaths()
        let changedCount: @MainActor @Sendable () -> Int = { context.changedModelsArray.count }
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.willSave, object: context, queue: nil
        ) { _ in
            MainActor.assumeIsolated { counts.append(String(changedCount())) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try operation()
        return counts.values
    }

    @MainActor
    private func makeSeededContainer(including changed: LocalCardRecord) throws -> ModelContainer {
        let container = try Persistence.makeContainer(inMemory: true)
        for index in 0..<100 {
            let record = try makeRecord(text: "Inactive", id: "inactive-\(index)")
            record.isInActiveSession = false
            container.mainContext.insert(record)
        }
        container.mainContext.insert(changed)
        try container.mainContext.save()
        return container
    }

    @MainActor
    private func makeRecord(text: String, id: String = "shared", userID: Int = 1) throws -> LocalCardRecord {
        let card = makeCard(text: text, id: id)
        return LocalCardRecord(card: card, userID: userID, queueIndex: 0, payload: try StorageCodec.encoder.encode(card))
    }

    @MainActor
    private func makeCard(text: String, id: String = "shared") -> StudyCard {
        StudyCard(
            id: id, noteId: nil, cardType: "recognition",
            prompt: .object(["cueText": .string(text)]), answer: .object(["meaning": .string("Meaning")]),
            state: .init(dueAt: nil, introducedAt: nil, failedAt: nil, queueState: "review", scheduler: nil,
                         source: .object([:])),
            answerAudioSource: "missing", createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }
}
