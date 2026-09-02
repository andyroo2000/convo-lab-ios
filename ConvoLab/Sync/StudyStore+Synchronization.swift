import Foundation

extension StudyStore {
    private struct SynchronizationFailure {
        let error: any Error
        let requiresRetry: Bool
    }

    private struct SynchronizationProgress {
        var firstError: (any Error)?
        var retryNeeded = false
        var refreshed = false
        var checkpointWasReset = false

        mutating func record(_ failure: SynchronizationFailure?) {
            guard let failure else { return }
            firstError = firstError ?? failure.error
            retryNeeded = retryNeeded || failure.requiresRetry
        }
    }

    private struct PullResult {
        let failure: SynchronizationFailure?
        let checkpointWasReset: Bool
        let responseWasDiscarded: Bool
    }

    func synchronize() async {
        await performSynchronization(requestingPromptRetryOnOutboxFailure: true)
    }

    private func performSynchronization(
        requestingPromptRetryOnOutboxFailure: Bool
    ) async {
        guard let userID = activeUserID, syncStatus != .syncing else { return }
        let diagnosticInterval = diagnostics.begin(.synchronization)
        var diagnosticOutcome: NativeDiagnosticOutcome = .cancelled
        defer { diagnostics.end(diagnosticInterval, outcome: diagnosticOutcome) }
        defer { reloadFailedStudyChanges() }
        let activationGeneration = accountActivationGeneration
        syncStatus = .syncing
        var progress = SynchronizationProgress()

        do {
            progress.record(await captureSynchronizationFailure(requiringRetry: true) {
                try await self.flushCardOutbox()
            })
            try requireCurrentActivation(userID, generation: activationGeneration)

            progress.record(await captureSynchronizationFailure(requiringRetry: true) {
                try await self.retryPendingDraftMutations(
                    userID: userID,
                    activationGeneration: activationGeneration
                )
            })
            try requireCurrentActivation(userID, generation: activationGeneration)

            progress.record(await captureSynchronizationFailure(requiringRetry: true) {
                try await self.flushSchedulingOutboxes()
            })
            try requireCurrentActivation(userID, generation: activationGeneration)

            let pullResult = await pullCardChangesForSynchronization(userID: userID)
            if pullResult.responseWasDiscarded {
                diagnosticOutcome = .discarded
                return
            }
            progress.record(pullResult.failure)
            progress.checkpointWasReset = pullResult.checkpointWasReset
            try requireCurrentActivation(userID, generation: activationGeneration)

            // Fetch small, user-visible metadata before session media preparation
            // consumes the shared production request bucket.
            progress.record(await captureSynchronizationFailure {
                try await self.refreshKnownKanji()
            })
            try requireCurrentActivation(userID, generation: activationGeneration)

            let sessionResult = await refreshSessionForSynchronization()
            progress.record(sessionResult.failure)
            progress.refreshed = sessionResult.refreshed
            try requireCurrentActivation(userID, generation: activationGeneration)

            progress.record(await captureSynchronizationFailure {
                try await self.refreshOfflineReserve(
                    userID: userID,
                    activationGeneration: activationGeneration,
                    clearingOtherRecords: progress.checkpointWasReset || progress.refreshed
                )
            })
            try requireCurrentActivation(userID, generation: activationGeneration)
        } catch {
            return
        }

        diagnosticOutcome = finishSynchronization(
            progress,
            userID: userID,
            activationGeneration: activationGeneration,
            requestingPromptRetryOnOutboxFailure: requestingPromptRetryOnOutboxFailure
        )
    }

    private func captureSynchronizationFailure(
        requiringRetry: Bool = false,
        operation: () async throws -> Void
    ) async -> SynchronizationFailure? {
        do {
            try await operation()
            return nil
        } catch {
            return SynchronizationFailure(
                error: error,
                requiresRetry: requiringRetry && Self.requiresAutomaticRetry(error)
            )
        }
    }

    private func requireCurrentActivation(
        _ userID: Int,
        generation: Int
    ) throws {
        guard isCurrentActivation(userID, generation: generation) else {
            throw CancellationError()
        }
    }

    private func pullCardChangesForSynchronization(userID: Int) async -> PullResult {
        do {
            let result = try await syncCoordinator.pullChanges(
                currentPublishedCards: publishedCards,
                publish: publish,
                reloadAfterCheckpointReset: {
                    if !self.lessonSessionIsPresented {
                        self.loadLocalCards(userID: userID)
                    }
                    self.loadLibraryCards(userID: userID)
                }
            )
            switch result {
            case .completed:
                return PullResult(
                    failure: nil,
                    checkpointWasReset: false,
                    responseWasDiscarded: false
                )
            case .checkpointReset:
                return PullResult(
                    failure: nil,
                    checkpointWasReset: true,
                    responseWasDiscarded: false
                )
            case .discardedStaleResponse:
                return PullResult(
                    failure: nil,
                    checkpointWasReset: false,
                    responseWasDiscarded: true
                )
            }
        } catch {
            return PullResult(
                failure: SynchronizationFailure(error: error, requiresRetry: false),
                checkpointWasReset: false,
                responseWasDiscarded: false
            )
        }
    }

    private func refreshSessionForSynchronization() async -> (
        refreshed: Bool,
        failure: SynchronizationFailure?
    ) {
        do {
            return (try await refreshSessionPreservingActiveLessons(), nil)
        } catch {
            return (false, SynchronizationFailure(error: error, requiresRetry: false))
        }
    }

    private func finishSynchronization(
        _ progress: SynchronizationProgress,
        userID: Int,
        activationGeneration: Int,
        requestingPromptRetryOnOutboxFailure: Bool
    ) -> NativeDiagnosticOutcome {
        let completedAt = Date.now
        if progress.refreshed {
            lastSessionRefreshAt = completedAt
        }
        if progress.retryNeeded, requestingPromptRetryOnOutboxFailure {
            outboxRetryRevision += 1
        }
        guard let firstError = progress.firstError else {
            // This timestamp represents a successful end-to-end sync, not merely
            // a successful session refresh after another domain failed.
            if progress.refreshed {
                lastSyncAt = completedAt
            }
            syncStatus = .idle
            return .succeeded
        }
        handleSyncError(
            firstError,
            for: userID,
            activationGeneration: activationGeneration
        )
        return .failed
    }

    private func publishedCards() -> StudySyncCoordinator.PublishedCards {
        StudySyncCoordinator.PublishedCards(
            session: cards,
            library: libraryCards,
            catalog: allCards
        )
    }

    private func publish(_ published: StudySyncCoordinator.PublishedCards) {
        cards = published.session
        libraryCards = published.library
        allCards = published.catalog
    }

    func pullCardChangesForProgressionRevalidation(
        userID: Int,
        activationGeneration: Int
    ) async throws {
        let result = try await syncCoordinator.pullChanges(
            currentPublishedCards: publishedCards,
            publish: publish,
            reloadAfterCheckpointReset: {
                self.loadLocalCards(userID: userID)
                self.loadLibraryCards(userID: userID)
            }
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        if result == .discardedStaleResponse { return }
        loadLibraryCards(userID: userID)
    }

    func synchronizeIfNeeded(maxAge: Duration) async {
        guard syncStatus != .syncing else { return }
        if consumedOutboxRetryRevision < outboxRetryRevision {
            // Give a failed mutation outbox one prompt retry. If that attempt
            // also fails, use session freshness to bound subsequent automatic
            // attempts until the normal max-age window expires. Consume only
            // the revision observed here so an interleaved eager failure is not
            // lost while this sync is suspended at a network await.
            consumedOutboxRetryRevision = outboxRetryRevision
            await performSynchronization(requestingPromptRetryOnOutboxFailure: false)
            return
        }
        let components = maxAge.components
        let maxAgeSeconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        if let lastSessionRefreshAt,
           Date.now.timeIntervalSince(lastSessionRefreshAt) < maxAgeSeconds
        {
            activateOfflineDueCards()
            return
        }
        await synchronize()
    }
}
