import XCTest
@testable import ConvoLab

@MainActor
final class StudyPublishedCardReconcilerTests: XCTestCase {
    func testRestoresDeletedCardAtItsOriginalPosition() {
        let first = makeCard(id: "first")
        let local = makeCard(id: "local", syncID: "server")
        let last = makeCard(id: "last")
        let canonical = makeCard(id: "server", syncID: "server")
        var cards = [first, local, last]
        var reconciler = StudyPublishedCardReconciler()

        reconciler.apply(
            changes(deleted: ["local"]),
            to: &cards
        )
        reconciler.apply(
            changes(restored: [(canonical, ["local", "server"])]),
            to: &cards
        )

        XCTAssertEqual(cards.map(\.id), ["first", "server", "last"])
    }

    func testRestorationDoesNotDuplicateExistingCardThroughCaseOrSyncAlias() {
        let local = makeCard(id: "local", syncID: "server")
        let existing = makeCard(id: "SERVER")
        let canonical = makeCard(id: "server", syncID: "server")
        var cards = [local, existing]
        var reconciler = StudyPublishedCardReconciler()

        reconciler.apply(
            changes(deleted: ["local"]),
            to: &cards
        )
        reconciler.apply(
            changes(restored: [(canonical, ["local", "server"])]),
            to: &cards
        )

        XCTAssertEqual(cards.map(\.id), ["server"])
        XCTAssertEqual(cards.first?.syncId, "server")
    }

    func testPruneMatchesIdentifiersCaseInsensitivelyAcrossLocalAndSyncIDs() {
        var cards = [
            makeCard(id: "local", syncID: "SERVER-ID"),
            makeCard(id: "keep"),
        ]

        StudyPublishedCardReconciler.prune(&cards, matching: ["server-id"])

        XCTAssertEqual(cards.map(\.id), ["keep"])
    }

    private func changes(
        deleted: Set<String> = [],
        restored: [(card: StudyCard, identifiers: Set<String>)] = []
    ) -> CardSyncFeedRepository.CommittedPageChanges {
        .init(
            deletedCardIdentifiers: deleted,
            restoredCards: restored.map {
                .init(card: $0.card, identifiers: $0.identifiers)
            }
        )
    }

    private func makeCard(id: String, syncID: String? = nil) -> StudyCard {
        StudyCard(
            id: id,
            syncId: syncID,
            noteId: nil,
            cardType: "recognition",
            prompt: .object(["cueText": .string(id)]),
            answer: .object(["meaning": .string("meaning")]),
            state: .init(
                dueAt: .now,
                introducedAt: .now,
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
