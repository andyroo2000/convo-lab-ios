import Foundation

@MainActor
final class StudySyncCoordinator {
    struct PublishedCards: Equatable {
        var session: [StudyCard]
        var library: [StudyCard]
        var catalog: [StudyCard]
    }

    typealias PageChanges = CardSyncFeedRepository.CommittedPageChanges
    typealias PullResult = CardSyncFeedRepository.PullResult

    private let activateOperation: (Int) -> Void
    private let deactivateOperation: () -> Void
    private let pullChangesOperation: @MainActor (
        _ onPageCommitted: @escaping @MainActor (PageChanges) -> Void
    ) async throws -> PullResult

    convenience init(repository: CardSyncFeedRepository) {
        self.init(
            activate: repository.activate(userID:),
            deactivate: repository.deactivate,
            pullChanges: { onPageCommitted in
                try await repository.pullChanges(onPageCommitted: onPageCommitted)
            }
        )
    }

    init(
        activate: @escaping (Int) -> Void,
        deactivate: @escaping () -> Void,
        pullChanges: @escaping @MainActor (
            _ onPageCommitted: @escaping @MainActor (PageChanges) -> Void
        ) async throws -> PullResult
    ) {
        activateOperation = activate
        deactivateOperation = deactivate
        pullChangesOperation = pullChanges
    }

    func activate(userID: Int) {
        activateOperation(userID)
    }

    func deactivate() {
        deactivateOperation()
    }

    func pullChanges(
        currentPublishedCards: @escaping () -> PublishedCards,
        publish: @escaping (PublishedCards) -> Void,
        reloadAfterCheckpointReset: () -> Void
    ) async throws -> PullResult {
        var sessionReconciler = StudyPublishedCardReconciler()
        var libraryReconciler = StudyPublishedCardReconciler()
        var catalogReconciler = StudyPublishedCardReconciler()
        let result = try await pullChangesOperation { changes in
            var published = currentPublishedCards()
            // A frozen lesson ignores ordinary session refreshes, but committed
            // tombstones must still disappear so review staging cannot recreate them.
            sessionReconciler.apply(changes, to: &published.session)
            libraryReconciler.apply(changes, to: &published.library)
            catalogReconciler.apply(changes, to: &published.catalog)
            publish(published)
        }

        switch result {
        case let .completed(deletedCardIdentifiers):
            prune(
                deletedCardIdentifiers,
                currentPublishedCards: currentPublishedCards,
                publish: publish
            )
        case let .checkpointReset(deletedCardIdentifiers):
            // Reload the reset replica first, then drop even frozen lesson
            // snapshots that could otherwise recreate deliberately purged rows.
            reloadAfterCheckpointReset()
            prune(
                deletedCardIdentifiers,
                currentPublishedCards: currentPublishedCards,
                publish: publish
            )
        case .discardedStaleResponse:
            break
        }
        return result
    }

    private func prune(
        _ identifiers: Set<String>,
        currentPublishedCards: () -> PublishedCards,
        publish: (PublishedCards) -> Void
    ) {
        var published = currentPublishedCards()
        StudyPublishedCardReconciler.prune(
            &published.session,
            matching: identifiers
        )
        StudyPublishedCardReconciler.prune(
            &published.library,
            matching: identifiers
        )
        StudyPublishedCardReconciler.prune(
            &published.catalog,
            matching: identifiers
        )
        publish(published)
    }
}
