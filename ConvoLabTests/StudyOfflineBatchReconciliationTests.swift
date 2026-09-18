import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testOfflineReconciliationBatchesCanonicalCardsWithinServerLimit() async throws {
        let fixture = try OfflineBatchFixture(cards: (0..<51).map { index in
            makeCard(id: "local-\(index)", syncId: ClientIdentifier.ulid(),
                     expression: "cached", dueAt: .distantPast)
        })
        let responses = try Dictionary(uniqueKeysWithValues: fixture.cards.map { card in
            (card.reviewCardID, String(decoding: try StorageCodec.encoder.encode(
                card.replacingVariantStatus("locked")
            ), as: UTF8.self))
        })
        let paths = LockedRequestPaths()
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            XCTAssertEqual(request.httpMethod, "POST")
            paths.append(request.url!.path)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: [String]])
            let ids = try XCTUnwrap(body["ids"])
            XCTAssertLessThanOrEqual(ids.count, 50)
            let cards = try ids.map { try XCTUnwrap(responses[$0]) }
            return Self.response(data: Data("{\"cards\":[\(cards.joined(separator: ","))]}".utf8))
        }

        try await fixture.reconcile(api: client)

        XCTAssertEqual(paths.values.count, 2)
        XCTAssertEqual(fixture.changes.count, 51)
        XCTAssertEqual(fixture.publicationSizes, [50, 1])
        XCTAssertTrue(try fixture.records().allSatisfy { !$0.isInActiveSession })
        XCTAssertTrue(try fixture.records().allSatisfy { try !StorageCodec.decoder.decode(StudyCard.self, from: $0.payload).isProgressionAvailable })
    }

    @MainActor
    func testOfflineBatchOmissionRequiresIndividualConfirmationBeforeDeletion() async throws {
        let card = makeCard(id: ClientIdentifier.ulid(), expression: "cached", dueAt: .distantPast)
        let fixture = try OfflineBatchFixture(cards: [card])
        let paths = LockedRequestPaths()
        let cardPath = "/api/study/cards/\(card.reviewCardID)"
        let cardData = try StorageCodec.encoder.encode(card)
        let client = makeClient { request in
            let path = try XCTUnwrap(request.url?.path)
            paths.append(path)
            if path == "/api/study/cards/batch" {
                return Self.response(data: Data(#"{"cards":[]}"#.utf8))
            }
            XCTAssertEqual(path, cardPath)
            return Self.response(data: cardData)
        }

        try await fixture.reconcile(api: client)

        XCTAssertEqual(paths.values.count, 2)
        XCTAssertEqual(try fixture.records().count, 1)
        XCTAssertNotNil(fixture.changes.first?.card)
    }

    @MainActor
    func testOfflineBatchResponsePreservesReviewQueuedDuringRequest() async throws {
        let card = makeCard(id: ClientIdentifier.ulid(), expression: "cached", dueAt: .distantPast)
        let fixture = try OfflineBatchFixture(cards: [card])
        let deferred = LockedDeferredResponse()
        let client = makeDeferredClient { request, completion in
            XCTAssertEqual(request.url?.path, "/api/study/cards/batch")
            deferred.hold(completion)
        }
        let task = Task { try await fixture.reconcile(api: client) }
        await deferred.waitUntilPending()
        fixture.context.insert(PendingMutation(kind: "review", userID: 1,
                                              resourceID: card.id, payload: Data()))
        try fixture.context.save()
        let response = try StorageCodec.encoder.encode(["cards": [card.replacingVariantStatus("locked")]])
        deferred.succeed(with: Self.response(data: response))
        try await task.value

        XCTAssertTrue(fixture.changes.isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.records().first).isInActiveSession)
    }
}

@MainActor
final class OfflineBatchFixture {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let cards: [StudyCard]
    var changes: [StudyOfflineCardReconciler.Change] = []
    var publicationSizes: [Int] = []
    var publishedCards: [StudyCard]
    var isCurrent = true

    init(cards: [StudyCard]) throws {
        self.cards = cards
        publishedCards = cards
        container = try Persistence.makeContainer(inMemory: true)
        for (index, card) in cards.enumerated() {
            let record = LocalCardRecord(card: card, userID: 1, queueIndex: index,
                                         payload: try StorageCodec.encoder.encode(card))
            record.serverUpdatedAt = Date(timeIntervalSince1970: Double(100 - index))
            context.insert(record)
        }
        try context.save()
    }

    func records() throws -> [LocalCardRecord] {
        try context.fetch(FetchDescriptor<LocalCardRecord>())
    }

    func reconcile(api: APIClient) async throws {
        try await StudyOfflineCardReconciler(api: api, context: context).reconcile(
            confirmedCards: [], at: .now, userID: 1,
            isCurrent: { self.isCurrent }, didReconcile: { changes in
                self.changes.append(contentsOf: changes)
                self.publicationSizes.append(changes.count)
                self.publishedCards = StudyOfflineCardChanges(changes).applying(to: self.publishedCards, studying: true)
            }
        )
    }
}
