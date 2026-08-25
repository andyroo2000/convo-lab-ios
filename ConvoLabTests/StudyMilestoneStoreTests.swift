import XCTest
@testable import ConvoLab

@MainActor
final class StudyMilestoneStoreTests: XCTestCase {
    // The iOS 26 XCTest runtime can double-free short-lived MainActor fixtures.
    // Keep the store and its suite defaults alive for the lifetime of the test process.
    private nonisolated(unsafe) static var retainedDefaults: [UserDefaults] = []
    private nonisolated(unsafe) static var retainedStores: [StudyMilestoneStore] = []

    func testCompletionAwardsHundredBurnedWhenSessionCrossesThreshold() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults: defaults)
        store.activate(userID: 1)
        store.beginReviewSession(burnedCount: 99)
        store.recordReview(burnedRecord(id: "review-1"))

        let completion = try XCTUnwrap(store.prepareCurrentSessionCompletion())

        XCTAssertEqual(completion.newAwards.map(\.id), [.burned100])
        XCTAssertEqual(store.earnedAwards.map(\.id), [.burned100])
        XCTAssertEqual(store.lastKnownBurnedCount, 100)
    }

    func testInterruptedQualifyingSessionRestoresAwardThenWrapUpData() throws {
        let defaults = try makeDefaults()
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession(burnedCount: 99)
        store.recordReview(burnedRecord(id: "review-1"))

        store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        let completion = try XCTUnwrap(store.prepareInterruptedCompletion())

        XCTAssertEqual(completion.newAwards.map(\.id), [.burned100])
        XCTAssertEqual(completion.records.map(\.id), ["review-1"])
        XCTAssertFalse(completion.celebrationPresented)

        store.markCelebrationPresented(sessionID: completion.id)
        store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        XCTAssertTrue(try XCTUnwrap(store.prepareInterruptedCompletion()).celebrationPresented)
    }

    func testInterruptedOrdinarySessionDoesNotForceAStaleWrapUp() throws {
        let defaults = try makeDefaults()
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession(burnedCount: 20)
        store.recordReview(burnedRecord(id: "review-1"))

        store = makeStore(defaults: defaults)
        store.activate(userID: 7)

        XCTAssertNil(store.prepareInterruptedCompletion())
    }

    func testPreparedOrdinaryCompletionRestoresWrapUpAfterRelaunch() throws {
        let defaults = try makeDefaults()
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession(burnedCount: 20)
        store.recordReview(burnedRecord(id: "review-1"))
        let prepared = try XCTUnwrap(store.prepareCurrentSessionCompletion())
        XCTAssertTrue(prepared.newAwards.isEmpty)

        store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        let restored = try XCTUnwrap(store.prepareInterruptedCompletion())

        XCTAssertEqual(restored.id, prepared.id)
        XCTAssertEqual(restored.records.map(\.id), ["review-1"])
        XCTAssertTrue(restored.newAwards.isEmpty)
    }

    func testExistingMilestonesAreBackfilledWithoutCelebration() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults: defaults)
        store.activate(userID: 1)
        store.beginReviewSession(burnedCount: 120)
        store.recordReview(
            record(
                id: "review-1",
                beforeStability: 10,
                afterStability: 20
            )
        )

        let completion = try XCTUnwrap(store.prepareCurrentSessionCompletion())

        XCTAssertTrue(completion.newAwards.isEmpty)
        XCTAssertEqual(store.earnedAwards.map(\.id), [.burned100])
    }

    func testMilestonesAreScopedPerAccount() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults: defaults)
        store.activate(userID: 1)
        store.beginReviewSession(burnedCount: 99)
        store.recordReview(burnedRecord(id: "review-1"))
        _ = store.prepareCurrentSessionCompletion()

        store.activate(userID: 2)
        XCTAssertTrue(store.earnedAwards.isEmpty)

        store.activate(userID: 1)
        XCTAssertEqual(store.earnedAwards.map(\.id), [.burned100])
    }

    private func burnedRecord(id: String) -> StudySessionReviewRecord {
        record(id: id, beforeStability: 364, afterStability: 365)
    }

    private func record(
        id: String,
        beforeStability: Double,
        afterStability: Double
    ) -> StudySessionReviewRecord {
        StudySessionReviewRecord(
            id: id,
            cardBefore: makeCard(id: id, stability: beforeStability),
            cardAfter: makeCard(id: id, stability: afterStability),
            rating: .good,
            durationMilliseconds: 1_000,
            reviewedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeCard(id: String, stability: Double) -> StudyCard {
        StudyCard(
            id: id,
            syncId: nil,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: .now,
                introducedAt: .now,
                failedAt: nil,
                queueState: "review",
                scheduler: .object(["stability": .number(stability)]),
                source: .object([:])
            ),
            answerAudioSource: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "StudyMilestoneStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        Self.retainedDefaults.append(defaults)
        return defaults
    }

    private func makeStore(defaults: UserDefaults) -> StudyMilestoneStore {
        let store = StudyMilestoneStore(defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }
}
