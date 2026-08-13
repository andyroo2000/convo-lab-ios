import XCTest
@testable import ConvoLab

@MainActor
final class StudySyncCoordinatorTests: XCTestCase {
    func testPublishesEachCommittedPageAndPrunesFinalTombstones() async throws {
        let deleted = makeCard(id: "deleted")
        let retained = makeCard(id: "retained")
        var published = StudySyncCoordinator.PublishedCards(
            session: [deleted, retained],
            library: [deleted, retained],
            catalog: [deleted, retained]
        )
        var publications: [StudySyncCoordinator.PublishedCards] = []
        let coordinator = StudySyncCoordinator(
            activate: { _ in },
            deactivate: {},
            pullChanges: { onPageCommitted in
                onPageCommitted(
                    .init(
                        deletedCardIdentifiers: ["deleted"],
                        restoredCards: []
                    )
                )
                return .completed(deletedCardIdentifiers: ["deleted"])
            }
        )

        _ = try await coordinator.pullChanges(
            currentPublishedCards: { published },
            publish: {
                published = $0
                publications.append($0)
            },
            reloadAfterCheckpointReset: {
                XCTFail("A completed pull must not reload checkpoint-reset state")
            }
        )

        XCTAssertEqual(publications.count, 2)
        XCTAssertEqual(publications.first?.session.map(\.id), ["retained"])
        XCTAssertEqual(published.session.map(\.id), ["retained"])
        XCTAssertEqual(published.library.map(\.id), ["retained"])
        XCTAssertEqual(published.catalog.map(\.id), ["retained"])
    }

    func testCheckpointResetReloadsBeforePruningEveryPublishedCollection() async throws {
        let stale = makeCard(id: "stale")
        let retained = makeCard(id: "retained")
        var published = StudySyncCoordinator.PublishedCards(
            session: [stale],
            library: [stale],
            catalog: [stale]
        )
        let coordinator = StudySyncCoordinator(
            activate: { _ in },
            deactivate: {},
            pullChanges: { _ in
                .checkpointReset(deletedCardIdentifiers: ["stale"])
            }
        )

        _ = try await coordinator.pullChanges(
            currentPublishedCards: { published },
            publish: { published = $0 },
            reloadAfterCheckpointReset: {
                published = .init(
                    session: [stale, retained],
                    library: [stale, retained],
                    catalog: [stale, retained]
                )
            }
        )

        XCTAssertEqual(published.session.map(\.id), ["retained"])
        XCTAssertEqual(published.library.map(\.id), ["retained"])
        XCTAssertEqual(published.catalog.map(\.id), ["retained"])
    }

    private func makeCard(id: String) -> StudyCard {
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
                scheduler: nil,
                source: .object([:])
            ),
            answerAudioSource: "missing",
            createdAt: .now,
            updatedAt: .now
        )
    }
}
