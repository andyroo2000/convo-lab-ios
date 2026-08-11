import XCTest
@testable import ConvoLab

@MainActor
final class StudySessionPolicyTests: XCTestCase {
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
            StudySessionPolicy.orderedCards(cards).map(\.id),
            ["review-first", "review-a", "review-b", "new-b", "new-a"]
        )
    }

    func testNextOfflineDueIgnoresActivePastAndNewCards() {
        let now = Date(timeIntervalSince1970: 1_000)
        let active = makeCard(
            id: "active",
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

    private func makeCard(
        id: String,
        queueState: String,
        dueAt: Date
    ) -> StudyCard {
        StudyCard(
            id: id,
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
            createdAt: .now,
            updatedAt: .now
        )
    }
}
