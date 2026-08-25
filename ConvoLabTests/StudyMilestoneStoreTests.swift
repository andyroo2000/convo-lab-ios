import XCTest
@testable import ConvoLab

@MainActor
final class StudyMilestoneStoreTests: XCTestCase {
    // The iOS 26 XCTest runtime can double-free short-lived MainActor fixtures.
    // Keep the store and its suite defaults alive for the lifetime of the test process.
    private nonisolated(unsafe) static var retainedDefaults: [UserDefaults] = []
    private nonisolated(unsafe) static var retainedStores: [StudyMilestoneStore] = []

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.deferredHandler = nil
        super.tearDown()
    }

    func testCompletionUsesPendingAwardsFromServerSnapshot() throws {
        let defaults = try makeDefaults()
        let store = makeStore(defaults: defaults)
        let award = makeAward(.burned100)
        store.activate(userID: 1)
        store.applyServerSnapshot(
            StudyMilestoneSnapshot(milestones: [award], pendingMilestones: [award])
        )
        store.beginReviewSession()
        store.recordReview(burnedRecord(id: "review-1"))

        let completion = try XCTUnwrap(
            store.prepareCurrentSessionCompletion(newAwards: [award])
        )

        XCTAssertEqual(completion.newAwards, [award])
        XCTAssertEqual(store.earnedAwards, [award])
    }

    func testInterruptedQualifyingSessionRestoresAwardThenWrapUpData() throws {
        let defaults = try makeDefaults()
        let award = makeAward(.burned100)
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession()
        store.recordReview(burnedRecord(id: "review-1"))

        store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        let completion = try XCTUnwrap(
            store.prepareInterruptedCompletion(newAwards: [award])
        )

        XCTAssertEqual(completion.newAwards, [award])
        XCTAssertEqual(completion.records.map(\.id), ["review-1"])
        XCTAssertFalse(completion.celebrationPresented)

        store.markCelebrationPresented(sessionID: completion.id)
        store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        XCTAssertTrue(
            try XCTUnwrap(
                store.prepareInterruptedCompletion(newAwards: [award])
            ).celebrationPresented
        )
    }

    func testPreparedCelebrationSurvivesALaterEmptyPendingSnapshot() throws {
        let store = makeStore(defaults: try makeDefaults())
        let award = makeAward(.burned100)
        store.activate(userID: 7)
        store.beginReviewSession()
        store.recordReview(burnedRecord(id: "review-1"))

        let prepared = try XCTUnwrap(
            store.prepareInterruptedCompletion(newAwards: [award])
        )
        let restored = try XCTUnwrap(store.prepareInterruptedCompletion(newAwards: []))

        XCTAssertEqual(prepared.newAwards, [award])
        XCTAssertEqual(restored.newAwards, [award])
        XCTAssertFalse(restored.celebrationPresented)
    }

    func testOfflinePreparedWrapUpCanPickUpALaterServerAward() throws {
        let store = makeStore(defaults: try makeDefaults())
        let award = makeAward(.burned100)
        store.activate(userID: 7)
        store.beginReviewSession()
        store.recordReview(burnedRecord(id: "review-1"))

        XCTAssertTrue(
            try XCTUnwrap(store.prepareCurrentSessionCompletion()).newAwards.isEmpty
        )

        let restored = try XCTUnwrap(
            store.prepareInterruptedCompletion(newAwards: [award])
        )
        XCTAssertEqual(restored.newAwards, [award])
    }

    func testInterruptedOrdinarySessionDoesNotForceAStaleWrapUp() throws {
        let defaults = try makeDefaults()
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession()
        store.recordReview(burnedRecord(id: "review-1"))

        store = makeStore(defaults: defaults)
        store.activate(userID: 7)

        XCTAssertNil(store.prepareInterruptedCompletion())
    }

    func testPreparedOrdinaryCompletionRestoresWrapUpAfterRelaunch() throws {
        let defaults = try makeDefaults()
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession()
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

    func testUndoingOnlyReviewRetractsInterruptedRecovery() throws {
        let defaults = try makeDefaults()
        var store = makeStore(defaults: defaults)
        store.activate(userID: 7)
        store.beginReviewSession()
        store.recordReview(burnedRecord(id: "review-1"))
        store.undoReview(eventID: "review-1")

        store = makeStore(defaults: defaults)
        store.activate(userID: 7)

        XCTAssertNil(store.prepareInterruptedCompletion(newAwards: [makeAward(.burned100)]))
    }

    func testServerHistoryIsCachedWithoutCreatingCelebration() throws {
        let defaults = try makeDefaults()
        let award = makeAward(.burned100, presentedAt: Date(timeIntervalSince1970: 2_000))
        var store = makeStore(defaults: defaults)
        store.activate(userID: 1)
        store.applyServerSnapshot(
            StudyMilestoneSnapshot(milestones: [award], pendingMilestones: [])
        )

        store = makeStore(defaults: defaults)
        store.activate(userID: 1)

        XCTAssertEqual(store.earnedAwards, [award])
        XCTAssertNil(store.prepareInterruptedCompletion())
    }

    func testMilestonesAreScopedPerAccount() throws {
        let defaults = try makeDefaults()
        let award = makeAward(.burned100)
        let store = makeStore(defaults: defaults)
        store.activate(userID: 1)
        store.applyServerSnapshot(
            StudyMilestoneSnapshot(milestones: [award], pendingMilestones: [award])
        )

        store.activate(userID: 2)
        XCTAssertTrue(store.earnedAwards.isEmpty)

        store.activate(userID: 1)
        XCTAssertEqual(store.earnedAwards, [award])
    }

    func testSynchronizeUsesServerHistoryAndPendingAwards() async throws {
        let api = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/milestones/evaluate")
            XCTAssertEqual(request.httpMethod, "POST")
            return Self.response(
                for: request,
                status: 200,
                json: """
                {
                  "milestones": [
                    {"id":"burned100","earnedAt":"2026-08-25T21:00:00.000000Z","presentedAt":null}
                  ],
                  "pendingMilestones": [
                    {"id":"burned100","earnedAt":"2026-08-25T21:00:00.000000Z","presentedAt":null}
                  ]
                }
                """
            )
        }
        let store = makeStore(api: api, defaults: try makeDefaults())
        store.activate(userID: 1)

        let snapshot = try await store.synchronize()

        XCTAssertEqual(snapshot.pendingMilestones.map(\.id), [.burned100])
        XCTAssertEqual(store.earnedAwards.map(\.id), [.burned100])
    }

    func testAcknowledgePresentationPostsMilestoneIDs() async throws {
        let api = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/study/milestones/present")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try requestBody(request)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: json) as? [String: Any]
            )
            XCTAssertEqual(payload["milestoneIds"] as? [String], ["burned100"])
            return Self.response(for: request, status: 204, json: "")
        }
        let store = makeStore(api: api, defaults: try makeDefaults())
        store.activate(userID: 1)

        try await store.acknowledgePresentation([.burned100])
    }

    private func makeAward(
        _ id: StudyMilestoneID,
        presentedAt: Date? = nil
    ) -> StudyMilestoneAward {
        StudyMilestoneAward(
            id: id,
            earnedAt: Date(timeIntervalSince1970: 1_000),
            presentedAt: presentedAt
        )
    }

    private func burnedRecord(id: String) -> StudySessionReviewRecord {
        StudySessionReviewRecord(
            id: id,
            cardBefore: makeCard(id: id, stability: 364),
            cardAfter: makeCard(id: id, stability: 365),
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

    private func makeStore(
        api: APIClient? = nil,
        defaults: UserDefaults
    ) -> StudyMilestoneStore {
        let store = StudyMilestoneStore(api: api, defaults: defaults)
        Self.retainedStores.append(store)
        return store
    }

    private func makeClient(handler: @escaping MockURLProtocol.Handler) -> APIClient {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://learning-os.example")!,
            session: URLSession(configuration: configuration)
        )
    }

    private nonisolated static func response(
        for request: URLRequest,
        status: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(json.utf8)
        )
    }
}
