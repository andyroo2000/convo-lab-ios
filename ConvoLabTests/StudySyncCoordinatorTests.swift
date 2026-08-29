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

    func testLaterFailureKeepsAlreadyCommittedPagePublishedWithoutFinalPrune() async {
        struct LaterPageError: Error {}

        let deleted = makeCard(id: "deleted")
        let retained = makeCard(id: "retained")
        var published = StudySyncCoordinator.PublishedCards(
            session: [deleted, retained],
            library: [deleted, retained],
            catalog: [deleted, retained]
        )
        var reloadCount = 0
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
                throw LaterPageError()
            }
        )

        do {
            _ = try await coordinator.pullChanges(
                currentPublishedCards: { published },
                publish: { published = $0 },
                reloadAfterCheckpointReset: { reloadCount += 1 }
            )
            XCTFail("The later-page failure should propagate")
        } catch is LaterPageError {
            // Expected: the first committed page must remain published.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(published.session.map(\.id), ["retained"])
        XCTAssertEqual(published.library.map(\.id), ["retained"])
        XCTAssertEqual(published.catalog.map(\.id), ["retained"])
        XCTAssertEqual(reloadCount, 0)
    }

    func testDiscardedStaleResponseDoesNotPublishReloadOrPrune() async throws {
        let stale = makeCard(id: "stale")
        var published = StudySyncCoordinator.PublishedCards(
            session: [stale],
            library: [stale],
            catalog: [stale]
        )
        var publishCount = 0
        var reloadCount = 0
        let coordinator = StudySyncCoordinator(
            activate: { _ in },
            deactivate: {},
            pullChanges: { _ in .discardedStaleResponse }
        )

        let result = try await coordinator.pullChanges(
            currentPublishedCards: { published },
            publish: {
                published = $0
                publishCount += 1
            },
            reloadAfterCheckpointReset: { reloadCount += 1 }
        )

        XCTAssertEqual(result, .discardedStaleResponse)
        XCTAssertEqual(published.session.map(\.id), ["stale"])
        XCTAssertEqual(published.library.map(\.id), ["stale"])
        XCTAssertEqual(published.catalog.map(\.id), ["stale"])
        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(reloadCount, 0)
    }

    func testConcurrentPullsAreSerialized() async throws {
        var callCount = 0
        var activeCallCount = 0
        var maximumActiveCallCount = 0
        var firstPullContinuation: CheckedContinuation<Void, Never>?
        let firstPullStarted = expectation(description: "first pull started")
        var published = StudySyncCoordinator.PublishedCards(
            session: [],
            library: [],
            catalog: []
        )
        let coordinator = StudySyncCoordinator(
            activate: { _ in },
            deactivate: {},
            pullChanges: { _ in
                callCount += 1
                activeCallCount += 1
                maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
                if callCount == 1 {
                    firstPullStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        firstPullContinuation = continuation
                    }
                }
                activeCallCount -= 1
                return .completed(deletedCardIdentifiers: [])
            }
        )

        let firstPull = Task {
            try await coordinator.pullChanges(
                currentPublishedCards: { published },
                publish: { published = $0 },
                reloadAfterCheckpointReset: {}
            )
        }
        await fulfillment(of: [firstPullStarted])
        let secondPull = Task {
            try await coordinator.pullChanges(
                currentPublishedCards: { published },
                publish: { published = $0 },
                reloadAfterCheckpointReset: {}
            )
        }
        await Task.yield()

        firstPullContinuation?.resume()
        _ = try await firstPull.value
        _ = try await secondPull.value

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(maximumActiveCallCount, 1)
    }

    func testCancelledQueuedPullExitsWithoutBlockingNextPull() async throws {
        var callCount = 0
        var firstPullContinuation: CheckedContinuation<Void, Never>?
        let firstPullStarted = expectation(description: "first pull started")
        let cancelledPullFinished = expectation(description: "cancelled pull finished")
        var published = StudySyncCoordinator.PublishedCards(
            session: [],
            library: [],
            catalog: []
        )
        let coordinator = StudySyncCoordinator(
            activate: { _ in },
            deactivate: {},
            pullChanges: { _ in
                callCount += 1
                if callCount == 1 {
                    firstPullStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        firstPullContinuation = continuation
                    }
                }
                return .completed(deletedCardIdentifiers: [])
            }
        )
        let pull: @MainActor () async throws -> StudySyncCoordinator.PullResult = {
            try await coordinator.pullChanges(
                currentPublishedCards: { published },
                publish: { published = $0 },
                reloadAfterCheckpointReset: {}
            )
        }

        let firstPull = Task { try await pull() }
        await fulfillment(of: [firstPullStarted])
        let cancelledPull = Task {
            defer { cancelledPullFinished.fulfill() }
            return try await pull()
        }
        await Task.yield()
        cancelledPull.cancel()

        await fulfillment(of: [cancelledPullFinished], timeout: 1)
        do {
            _ = try await cancelledPull.value
            XCTFail("The queued pull should throw CancellationError")
        } catch is CancellationError {
            // Expected: it leaves the permit queue without entering the operation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(callCount, 1)

        let nextPull = Task { try await pull() }
        await Task.yield()
        firstPullContinuation?.resume()
        _ = try await firstPull.value
        _ = try await nextPull.value

        XCTAssertEqual(callCount, 2)
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
