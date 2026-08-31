import XCTest
@testable import ConvoLab

@MainActor
final class StudySessionPolicyTests: XCTestCase {
    func testEligibleCardsUseLocalAndServerAliasesForExclusionAndDeduplication() {
        let pending = makeCard(
            id: "local-pending",
            syncID: "server-pending",
            queueState: "review",
            dueAt: .now
        )
        let first = makeCard(
            id: "local-duplicate",
            syncID: "server-duplicate",
            queueState: "review",
            dueAt: .now
        )
        let duplicate = makeCard(
            id: "SERVER-DUPLICATE",
            queueState: "review",
            dueAt: .now
        )
        let unique = makeCard(id: "unique", queueState: "review", dueAt: .now)

        XCTAssertEqual(
            StudySessionPolicy.eligibleCards(
                from: [pending, first, duplicate, unique],
                excluding: ["SERVER-PENDING"]
            ).map(\.id),
            ["local-duplicate", "unique"]
        )
    }

    func testSessionOrderingPrioritizesDueReviewsAndKeepsNewCardOrderStable() {
        let now = Date(timeIntervalSince1970: 1_000)
        let cards = [
            makeCard(id: "review-b", queueState: "review", dueAt: now.addingTimeInterval(10)),
            makeCard(id: "new-b", queueState: "new", dueAt: now),
            makeCard(id: "review-a", queueState: "review", dueAt: now.addingTimeInterval(10)),
            makeCard(id: "new-a", queueState: "new", dueAt: now),
            makeCard(id: "review-first", queueState: "review", dueAt: now),
        ]

        XCTAssertEqual(
            StudySessionPolicy.offlineOrderedCards(cards).map(\.id),
            ["review-first", "review-a", "review-b", "new-b", "new-a"]
        )
    }

    func testNextOfflineDueIgnoresActivePastAndNewCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let active = makeCard(
            id: "active",
            syncID: "active-server",
            queueState: "review",
            dueAt: now.addingTimeInterval(5)
        )
        let expected = makeCard(
            id: "expected",
            queueState: "relearning",
            dueAt: now.addingTimeInterval(10)
        )
        let library = [
            active,
            makeCard(
                id: "ACTIVE-SERVER",
                queueState: "review",
                dueAt: now.addingTimeInterval(8)
            ),
            makeCard(id: "past", queueState: "review", dueAt: now.addingTimeInterval(-1)),
            makeCard(id: "new", queueState: "new", dueAt: now.addingTimeInterval(1)),
            makeCard(id: "later", queueState: "learning", dueAt: now.addingTimeInterval(20)),
            expected,
        ]

        XCTAssertEqual(
            StudySessionPolicy.nextOfflineDueAt(
                activeCards: [active],
                libraryCards: library,
                at: now
            ),
            expected.state.dueAt
        )
    }

    func testProgressionLockedCardsAreExcludedFromOnlineAndOfflineQueues() {
        let now = Date(timeIntervalSince1970: 1_000)
        let locked = makeCard(
            id: "locked",
            queueState: "review",
            dueAt: now.addingTimeInterval(-1),
            variantGroupID: "family-1",
            variantStatus: "locked"
        )
        let available = makeCard(
            id: "available",
            queueState: "review",
            dueAt: now,
            variantGroupID: "family-1",
            variantStatus: "available"
        )

        XCTAssertEqual(
            StudySessionPolicy.eligibleCards(
                from: [locked, available],
                excluding: []
            ).map(\.id),
            ["available"]
        )
        XCTAssertFalse(locked.isEligibleForOfflineStudy(at: now))
        XCTAssertEqual(
            StudySessionPolicy.nextOfflineDueAt(
                activeCards: [],
                libraryCards: [locked, available],
                at: now.addingTimeInterval(-2)
            ),
            available.state.dueAt
        )
    }

    private func makeCard(
        id: String,
        syncID: String? = nil,
        queueState: String,
        dueAt: Date,
        variantGroupID: String? = nil,
        variantStatus: String? = nil
    ) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncID,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: dueAt,
                introducedAt: .now,
                failedAt: nil,
                queueState: queueState,
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            variantGroupId: variantGroupID,
            variantStatus: variantStatus,
            createdAt: .now,
            updatedAt: .now
        )
    }
}
