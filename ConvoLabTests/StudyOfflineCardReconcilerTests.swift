import Foundation
import SwiftData
import XCTest
@testable import ConvoLab

extension StudyStoreTests {
    @MainActor
    func testOfflineReconciliationProtectsEveryPendingMutationKindAndAlias() async throws {
        for kind in ["review", "cardAction", "cardCreate", "cardUpdate", "cardDelete"] {
            let fixture = try makeOfflineReconciliationFixture()
            fixture.context.insert(PendingMutation(
                kind: kind, userID: 1, resourceID: fixture.card.reviewCardID.uppercased(),
                payload: Data()
            ))
            try fixture.context.save()
            let client = makeClient { _ in
                XCTFail("Pending \(kind) must not be reconciled")
                throw URLError(.badURL)
            }

            try await fixture.reconcile(api: client)

            XCTAssertEqual(fixture.record.payload, fixture.originalPayload)
            XCTAssertTrue(fixture.changes.isEmpty)
        }
    }

    @MainActor
    func testOfflineReconciliationRefreshesRescheduledCardWithoutActivatingIt() async throws {
        let fixture = try makeOfflineReconciliationFixture()
        let dueAt = Date.now.addingTimeInterval(10 * 86_400)
        let serverCard = makeCard(
            id: fixture.card.reviewCardID.uppercased(), expression: "canonical",
            dueAt: dueAt
        )
        let response = try StorageCodec.encoder.encode(serverCard)
        let client = makeClient { _ in Self.response(data: response) }

        try await fixture.reconcile(api: client)

        let persisted = try fixture.persistedCard()
        XCTAssertEqual(persisted.id, fixture.card.id)
        XCTAssertEqual(try XCTUnwrap(persisted.state.dueAt).timeIntervalSince(dueAt), 0, accuracy: 0.001)
        XCTAssertFalse(fixture.record.isInActiveSession)
        XCTAssertFalse(persisted.isEligibleForOfflineStudy(at: .now))
        XCTAssertTrue(persisted.isEligibleForOfflineStudy(at: dueAt))
        let change = try XCTUnwrap(fixture.changes.first)
        XCTAssertTrue(change.applying(to: [fixture.card], studyDate: .now).isEmpty)
        XCTAssertEqual(change.applying(to: [fixture.card]).first?.promptText, "canonical")
    }

    @MainActor
    func testOfflineReconciliationRemovesConfirmedDeletedCard() async throws {
        let fixture = try makeOfflineReconciliationFixture()
        let client = makeClient { _ in Self.response(statusCode: 404, data: Data()) }

        try await fixture.reconcile(api: client)

        XCTAssertTrue(try fixture.context.fetch(FetchDescriptor<LocalCardRecord>()).isEmpty)
        let change = try XCTUnwrap(fixture.changes.first)
        XCTAssertTrue(change.applying(to: [fixture.card]).isEmpty)
    }

    @MainActor
    func testOfflineReconciliationLeavesCacheIntactOnNetworkFailure() async throws {
        let fixture = try makeOfflineReconciliationFixture()
        let client = makeClient { _ in throw URLError(.notConnectedToInternet) }

        do {
            try await fixture.reconcile(api: client)
            XCTFail("The failed repair must remain retryable")
        } catch is URLError {}

        XCTAssertEqual(fixture.record.payload, fixture.originalPayload)
        XCTAssertTrue(fixture.changes.isEmpty)
    }

    @MainActor
    func testOfflineReconciliationDiscardsResponseAfterLocalWorkChanges() async throws {
        for changePayload in [false, true] {
            let fixture = try makeOfflineReconciliationFixture()
            let response = try StorageCodec.encoder.encode(fixture.card.replacingVariantStatus("locked"))
            let deferred = LockedDeferredResponse()
            let client = makeDeferredClient { _, completion in deferred.hold(completion) }
            let repair = Task { try await fixture.reconcile(api: client) }
            await deferred.waitUntilPending()
            if changePayload {
                fixture.record.replacePayload(encoded: try StorageCodec.encoder.encode(
                    fixture.card.replacingVariantStatus("available")
                ))
            } else {
                fixture.context.insert(PendingMutation(
                    kind: "review", userID: 1, resourceID: fixture.card.id, payload: Data()
                ))
            }
            try fixture.context.save()
            let newestPayload = fixture.record.payload
            deferred.succeed(with: Self.response(data: response))
            try await repair.value

            XCTAssertEqual(fixture.record.payload, newestPayload)
            XCTAssertTrue(fixture.changes.isEmpty)
        }
    }

    @MainActor
    func testOfflineReconciliationDiscardsResponseAfterAccountActivationChanges() async throws {
        let fixture = try makeOfflineReconciliationFixture()
        let response = try StorageCodec.encoder.encode(fixture.card.replacingVariantStatus("locked"))
        let deferred = LockedDeferredResponse()
        let client = makeDeferredClient { _, completion in deferred.hold(completion) }
        let repair = Task { try await fixture.reconcile(api: client) }
        await deferred.waitUntilPending()
        fixture.isCurrent = false
        deferred.succeed(with: Self.response(data: response))

        do {
            try await repair.value
            XCTFail("An obsolete account activation must cancel the repair")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.record.payload, fixture.originalPayload)
        XCTAssertTrue(fixture.changes.isEmpty)
    }

    @MainActor
    private func makeOfflineReconciliationFixture() throws -> OfflineReconciliationFixture {
        try OfflineReconciliationFixture(card: makeCard(
            id: "local-card", syncId: "server-card", expression: "cached", dueAt: .distantPast
        ))
    }
}

@MainActor
private final class OfflineReconciliationFixture {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let card: StudyCard
    let record: LocalCardRecord
    let originalPayload: Data
    var isCurrent = true
    var changes: [StudyOfflineCardReconciler.Change] = []

    init(card: StudyCard) throws {
        container = try Persistence.makeContainer(inMemory: true)
        self.card = card
        originalPayload = try StorageCodec.encoder.encode(card)
        record = LocalCardRecord(card: card, userID: 1, queueIndex: 0, payload: originalPayload)
        context.insert(record)
        try context.save()
    }

    func reconcile(api: APIClient) async throws {
        try await StudyOfflineCardReconciler(api: api, context: context).reconcile(
            confirmedCards: [], at: .now, userID: 1,
            isCurrent: { self.isCurrent },
            didReconcile: { self.changes.append($0) }
        )
    }

    func persistedCard() throws -> StudyCard {
        try StorageCodec.decoder.decode(StudyCard.self, from: record.payload)
    }
}
