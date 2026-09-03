import XCTest
@testable import ConvoLab

extension StudyAchievementTests {
    @MainActor
    func testMissingOpeningProgressDoesNotReplayHistoricalAwards() async throws {
        let defaults = try makeDefaults()
        let client = makeClient()
        let store = StudyAchievementStore(api: client, defaults: defaults)
        store.activate(userID: 41)
        store.beginReviewSession()
        store.recordReview(
            makeReviewRecord(id: "review-1", reviewedAt: ISO8601Milliseconds.date(from: "2026-08-28T12:00:00.000Z")!))

        try installAchievementResponses(awards: [
            award(id: "stable.first", date: "2026-08-01T12:00:00.000Z"),
            award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z"),
        ])
        await store.refresh()

        XCTAssertEqual(store.prepareCurrentSessionCompletion()?.newAwardIDs, ["reviews.first"])
    }

    @MainActor
    func testSessionCompletionPersistsMultipleAwardsUntilWrapUpConsumesIt() async throws {
        let defaults = try makeDefaults()
        let client = makeClient()
        try installAchievementResponses(awards: [])
        let store = StudyAchievementStore(api: client, defaults: defaults)
        store.activate(userID: 41)
        await store.refresh()
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))

        try installAchievementResponses(awards: [
            award(id: "voice.first", date: "2026-08-28T12:02:00.000Z"),
            award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z"),
        ])
        await store.refresh()

        let completion = try XCTUnwrap(store.prepareCurrentSessionCompletion())
        XCTAssertEqual(completion.newAwardIDs, ["reviews.first", "voice.first"])
        store.markCelebrationPresented(sessionID: completion.id)

        let relaunched = StudyAchievementStore(api: client, defaults: defaults)
        relaunched.activate(userID: 41)
        let restored = try XCTUnwrap(relaunched.prepareInterruptedCompletion())
        XCTAssertEqual(restored.newAwardIDs, ["reviews.first", "voice.first"])
        XCTAssertTrue(restored.celebrationPresented)

        relaunched.consumeCompletion(sessionID: restored.id)
        let afterWrapUp = StudyAchievementStore(api: client, defaults: defaults)
        afterWrapUp.activate(userID: 41)
        XCTAssertNil(afterWrapUp.prepareInterruptedCompletion())
    }

    @MainActor
    func testInterruptedCompletionDropsAnAwardRevokedByTheServer() async throws {
        let defaults = try makeDefaults()
        let client = makeClient()
        try installAchievementResponses(awards: [])
        let store = StudyAchievementStore(api: client, defaults: defaults)
        store.activate(userID: 41)
        await store.refresh()
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))

        try installAchievementResponses(awards: [award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z")])
        await store.refresh()
        XCTAssertEqual(store.prepareInterruptedCompletion()?.newAwardIDs, ["reviews.first"])

        let relaunched = StudyAchievementStore(api: client, defaults: defaults)
        relaunched.activate(userID: 41)
        try installAchievementResponses(awards: [])
        await relaunched.refresh()

        XCTAssertNil(relaunched.prepareInterruptedCompletion())
        XCTAssertNil(relaunched.achievement(id: "reviews.first"))

        let afterSecondRelaunch = StudyAchievementStore(api: client, defaults: defaults)
        afterSecondRelaunch.activate(userID: 41)
        XCTAssertNil(afterSecondRelaunch.prepareInterruptedCompletion())
    }

    @MainActor
    func testPreparedWrapUpCanPickUpAnAwardThatArrivesAfterRelaunch() async throws {
        let defaults = try makeDefaults()
        let client = makeClient()
        try installAchievementResponses(awards: [])
        let store = StudyAchievementStore(api: client, defaults: defaults)
        store.activate(userID: 41)
        await store.refresh()
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))

        XCTAssertEqual(store.prepareCurrentSessionCompletion()?.newAwardIDs, [])

        let relaunched = StudyAchievementStore(api: client, defaults: defaults)
        relaunched.activate(userID: 41)
        try installAchievementResponses(awards: [award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z")])
        await relaunched.refresh()

        XCTAssertEqual(relaunched.prepareInterruptedCompletion()?.newAwardIDs, ["reviews.first"])
    }

    @MainActor
    func testFinishedOptimisticCelebrationReopensOnlyForLateAuthoritativeAward() async throws {
        let defaults = try makeDefaults()
        let client = makeClient()
        try installAchievementResponses(awards: [])
        let store = StudyAchievementStore(api: client, defaults: defaults)
        store.activate(userID: 41)
        await store.refresh()
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))

        try installAchievementResponses(awards: [award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z")])
        await store.refresh()
        let optimistic = try XCTUnwrap(store.prepareCurrentSessionCompletion())
        XCTAssertEqual(optimistic.newAwardIDs, ["reviews.first"])
        store.markCelebrationPresented(sessionID: optimistic.id)

        try installAchievementResponses(awards: [
            award(id: "reviews.first", date: "2026-08-28T12:01:00.000Z"),
            award(id: "voice.first", date: "2026-08-28T12:02:00.000Z"),
        ])
        await store.refresh()

        let authoritative = try XCTUnwrap(store.prepareCurrentSessionCompletion())
        XCTAssertEqual(authoritative.newAwardIDs, ["reviews.first", "voice.first"])
        XCTAssertFalse(authoritative.celebrationPresented)
    }

    @MainActor
    func testUndoAndCancelPreventAnOrdinarySessionFromBeingRestored() async throws {
        let defaults = try makeDefaults()
        let client = makeClient()
        try installAchievementResponses(awards: [])
        let store = StudyAchievementStore(api: client, defaults: defaults)
        store.activate(userID: 41)
        await store.refresh()
        store.beginReviewSession()
        store.recordReview(makeReviewRecord(id: "review-1"))
        store.undoReview(eventID: "review-1")
        XCTAssertNil(store.prepareCurrentSessionCompletion())

        store.recordReview(makeReviewRecord(id: "review-2"))
        store.cancelCurrentSession()
        XCTAssertNil(store.prepareInterruptedCompletion())
    }
}
