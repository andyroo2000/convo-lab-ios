import Foundation

extension StudyStore {
    private struct OversizedLessonSessionError: LocalizedError {
        var errorDescription: String? {
            "The lesson response contained more cards than the client contract allows."
        }
    }

    func loadNextReviewBatch() async {
        guard let userID = activeUserID, sessionKind == "reviews", cards.isEmpty else {
            return
        }

        // The offline reserve may already contain cards that became due after the
        // previous batch was loaded. Promote that delta before doing a full sync;
        // otherwise refreshSession can replace the active markers before these
        // locally ready cards ever reach the player.
        loadLibraryCards(userID: userID)
        activateOfflineDueCards()
        if cards.isEmpty {
            await synchronize()
            guard activeUserID == userID else { return }
            activateOfflineDueCards()
        }

        guard activeUserID == userID, !cards.isEmpty else { return }
        sessionInitialCardCount = cards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
    }

    @discardableResult
    func refreshSession() async throws -> Bool {
        guard let load = try await sessionLoadingService.load(.reviews) else { return false }
        try await applyReviewSessionLoad(load, resettingSessionProgress: true)
        return true
    }

    func revalidateRemainingReviewQueue(
        expectedStudySurfaceRevision: Int? = nil
    ) async throws {
        guard sessionKind == "reviews", !lessonSessionIsPresented else { return }
        if let expectedStudySurfaceRevision {
            guard studySurfaceRevision == expectedStudySurfaceRevision else { return }
        }
        guard let load = try await sessionLoadingService.load(.reviews) else { return }
        if let expectedStudySurfaceRevision {
            guard studySurfaceRevision == expectedStudySurfaceRevision else { return }
        }
        try await applyReviewSessionLoad(load, resettingSessionProgress: false)
    }

    private func applyReviewSessionLoad(
        _ load: StudySessionLoad,
        resettingSessionProgress: Bool
    ) async throws {
        let userID = load.userID
        let session = load.response.session
        let pendingReviewState = try reviewOutbox.pendingState()
        let activeCards = try eligibleSessionCards(
            from: session.cards,
            pendingReviewState: pendingReviewState
        )
        let resolvedSettings = StudySettingsPolicy.settings(
            from: session.overview,
            fallbackReviewTimeBudget: resolvedReviewTimeBudget(),
            existingLaneWeights: studySettings?.newCardLaneWeights
        )
        setOverview(StudySettingsPolicy.applying(
            resolvedSettings,
            to: session.overview,
            preservingJLPTMasteryFrom: overview
        ))
        studySettings = resolvedSettings
        studySurfaceRevision += 1
        cards = activeCards
        sessionKind = "reviews"
        if resettingSessionProgress {
            sessionInitialCardCount = activeCards.count
            sessionCompletedCardIDs = []
            masteryAnimation = nil
        } else {
            sessionInitialCardCount = max(
                sessionInitialCardCount,
                sessionCompletedCardIDs.count + activeCards.count
            )
        }
        apply(pendingReviewState)
        try localCardRepository.replaceActiveSession(with: activeCards, userID: userID)
        loadLibraryCards(userID: userID)
        scheduleNextOfflineActivation()

        let mediaURLs = activeCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-study")
        if sessionLoadingService.isCurrent(load) {
            markPrepared(cards: activeCards)
            lastSessionRefreshAt = .now
        }
    }

    /// A foreground sync must not replace a frozen lesson batch with review cards.
    /// The lesson remains stable until the user finishes it or explicitly leaves it.
    func refreshSessionPreservingActiveLessons() async throws -> Bool {
        guard !lessonSessionIsPresented else { return false }
        return try await refreshSession()
    }

    @discardableResult
    func refreshLessons() async throws -> Bool {
        let loadKind: StudySessionLoadKind = if let activeLessonCohortID {
            .introductionCohort(activeLessonCohortID)
        } else {
            .lessons
        }
        guard let load = try await sessionLoadingService.load(loadKind) else { return false }
        let userID = load.userID
        let session = load.response.session
        // Both ordinary and introduction-cohort lesson endpoints are bounded by
        // the API's lesson_batch_size setting (currently 3...10).
        guard session.cards.count <= StudySettingsPolicy.lessonBatchSizeRange.upperBound else {
            throw OversizedLessonSessionError()
        }
        let pendingReviewState = try reviewOutbox.pendingState()
        let lessonCards = try eligibleSessionCards(
            from: session.cards,
            pendingReviewState: pendingReviewState
        )
        let resolvedSettings = StudySettingsPolicy.settings(
            from: session.overview,
            fallbackReviewTimeBudget: resolvedReviewTimeBudget(),
            existingLaneWeights: studySettings?.newCardLaneWeights
        )
        setOverview(StudySettingsPolicy.applying(
            resolvedSettings,
            to: session.overview,
            preservingJLPTMasteryFrom: overview
        ))
        studySettings = resolvedSettings
        studySurfaceRevision += 1
        cards = lessonCards
        sessionKind = "lessons"
        sessionInitialCardCount = lessonCards.count
        sessionCompletedCardIDs = []
        masteryAnimation = nil
        if lessonSessionIsPresented {
            // Keep the review queue durable while its presentation is suspended.
            // Lesson cards are cached locally without taking over active-review flags.
            try localCardRepository.mergeOfflineReserve(
                lessonCards,
                userID: userID,
                preservingActiveSessionOrder: true
            )
        } else {
            try localCardRepository.replaceActiveSession(with: lessonCards, userID: userID)
        }
        loadLibraryCards(userID: userID)
        let mediaURLs = lessonCards.flatMap(\.mediaURLs)
        await mediaCache.prepare(urls: mediaURLs, category: "active-lesson")
        if sessionLoadingService.isCurrent(load) {
            markPrepared(cards: lessonCards)
        }
        return true
    }

    private func eligibleSessionCards(
        from candidates: [StudyCard],
        pendingReviewState: PendingReviewState
    ) throws -> [StudyCard] {
        guard activeUserID != nil else { return [] }
        let pendingDeleteIdentifiers = try cardOutbox.pendingDeleteIdentifiers()
        let pendingActionIdentifiers = try cardActionOutbox.pendingIdentifiers()
        let candidatesWithoutPendingDeletes = try candidates.compactMap { card -> StudyCard? in
            guard !StudyCardIdentity.matches(card, any: pendingDeleteIdentifiers) else {
                return nil
            }
            let localCard = try currentLocalCardIfPresent(for: card)
            let resolvedCard = localCard.map {
                card.resolvingProgressionMetadata(fallingBackTo: $0)
            } ?? card
            guard StudyCardIdentity.matches(
                resolvedCard,
                any: pendingActionIdentifiers
            ) else {
                return resolvedCard
            }
            // A server session fetched while an action is queued must not replace
            // the durable optimistic schedule with the older server snapshot.
            return localCard ?? resolvedCard
        }
        return StudySessionPolicy.eligibleCards(
            from: candidatesWithoutPendingDeletes,
            excluding: pendingReviewState.cardIDs
        )
    }

    func retryLessonCard(_ card: StudyCard) {
        guard sessionKind == "lessons",
              let index = cards.firstIndex(where: {
                  StudyCardIdentity.matches($0, card)
              })
        else {
            return
        }
        let retryCard = cards.remove(at: index)
        cards.append(retryCard)
    }

    @discardableResult
    func recordReview(
        card: StudyCard,
        rating: ReviewRating,
        duration: Duration?,
        reviewedAt: Date = .now
    ) async -> String? {
        await recordReviewResult(
            card: card,
            rating: rating,
            duration: duration,
            reviewedAt: reviewedAt
        )?.eventID
    }

    @discardableResult
    func recordReviewResult(
        card: StudyCard,
        rating: ReviewRating,
        duration: Duration?,
        reviewedAt: Date = .now
    ) async -> StagedStudyReview? {
        guard let userID = activeUserID else { return nil }
        guard storageMode == .persistent else {
            storageWriteErrorMessage = StorageWriteUnavailableError(domain: .study)
                .localizedDescription
            return nil
        }
        defer { reloadFailedStudyChanges() }
        let activationGeneration = accountActivationGeneration
        let presentationRevision = studySurfaceRevision
        var stagedReview: StagedStudyReview?
        do {
            // Scheduling must succeed before the durable event is staged. If the
            // FSRS engine violates its rating-state contract, surface that error
            // without leaving a review queued against an unchanged local card.
            let staged = try reviewRecordingService.stage(
                card: card,
                rating: rating,
                duration: duration,
                reviewedAt: reviewedAt,
                deviceID: deviceID,
                queueIndex: cards.count
            )
            stagedReview = staged
            reviewOutboxRevision &+= 1
            let currentCard = staged.cardBefore
            let updatedCard = staged.cardAfter
            let identifiers = StudyCardIdentity.identifiers(for: currentCard)
                .union(StudyCardIdentity.identifiers(for: card))
            sessionCompletedCardIDs.insert(currentCard.id)
            // The animation retains this reviewed card as its presentation snapshot until
            // dismissal, while the queue can optimistically advance underneath it.
            masteryAnimation = nil
            // Compare the same local FSRS projection on both sides. The server annotation
            // belongs to the pre-review state and cannot describe this optimistic review.
            let oldLevel = currentCard.fsrsMasteryLevel
            let newLevel = updatedCard.fsrsMasteryLevel
            masteryAnimation = (
                id: UUID(),
                card: currentCard,
                label: currentCard.presentation.back.heading
                    ?? currentCard.presentation.front.heading
                    ?? "This item",
                fromLevel: oldLevel.rawValue,
                toLevel: newLevel.rawValue,
                passed: rating != .again
            )
            sessionFailureWasPresentByEventID[staged.eventID] = sessionFailedCardIDs.contains(
                currentCard.id
            )
            if rating == .again {
                sessionFailedCardIDs.insert(currentCard.id)
            } else {
                sessionFailedCardIDs.remove(currentCard.id)
            }
            var pendingState = PendingReviewState(
                newlyFailedCardIDs: newlyFailedCardIDs,
                retainedFailedCardIDs: retainedFailedCardIDs,
                resolvedFailedCardIDs: resolvedFailedCardIDs
            )
            pendingState.record(
                card: PendingReviewCardState(card: currentCard),
                rating: rating
            )
            apply(pendingState)
            consumeOverviewCount(for: currentCard)
            cards.removeAll { StudyCardIdentity.matches($0, any: identifiers) }
            if let index = libraryCards.firstIndex(where: {
                StudyCardIdentity.matches($0, any: identifiers)
            }) {
                libraryCards[index] = updatedCard
            } else {
                libraryCards.append(updatedCard)
            }
            scheduleNextOfflineActivation()
            if try cardOutbox.hasPendingCreate(for: currentCard.id) {
                try await flushCardOutbox()
            }
            let flushResult: ReviewEventFlushResult
            var deferredFlushError: (any Error)?
            do {
                flushResult = try await flushSchedulingOutboxes()
            } catch let failure as ReviewEventFlushFailure {
                flushResult = failure.result
                deferredFlushError = failure.underlyingError
            }
            let currentReviewWasProgressionLocked = flushResult
                .progressionLockedEventIDs
                .contains(staged.eventID)
            if currentReviewWasProgressionLocked {
                stagedReview = nil
                try rollBackSessionTrackingForProgressionLock(
                    eventID: staged.eventID,
                    card: currentCard,
                    userID: userID
                )
            }
            if currentCard.belongsToLearningProgression
                || !flushResult.progressionLockedEventIDs.isEmpty
            {
                scheduleProgressionRevalidation(
                    userID: userID,
                    activationGeneration: activationGeneration,
                    presentationRevision: presentationRevision
                )
            }
            if let deferredFlushError {
                throw deferredFlushError
            }
            return stagedReview
        } catch {
            var schedulerStateRecovered = false
            if error is FSRSReviewScheduler.InvalidSchedulerTimestampError {
                schedulerStateRecovered = await recoverCorruptedSchedulerState(
                    for: card,
                    userID: userID,
                    activationGeneration: activationGeneration
                )
            }
            markOutboxRetryNeeded(for: error)
            if !schedulerStateRecovered {
                handleSyncError(
                    error,
                    for: userID,
                    activationGeneration: activationGeneration
                )
            }
            return stagedReview
        }
    }

    private func scheduleProgressionRevalidation(
        userID: Int,
        activationGeneration: Int,
        presentationRevision: Int
    ) {
        Task { [weak self] in
            guard let self,
                  isCurrentActivation(userID, generation: activationGeneration),
                  studySurfaceRevision == presentationRevision
            else { return }
            var firstError: (any Error)?
            do {
                try await pullCardChangesForProgressionRevalidation(
                    userID: userID,
                    activationGeneration: activationGeneration
                )
            } catch {
                firstError = error
            }
            guard isCurrentActivation(userID, generation: activationGeneration),
                  studySurfaceRevision == presentationRevision
            else { return }
            do {
                try await revalidateRemainingReviewQueue(
                    expectedStudySurfaceRevision: presentationRevision
                )
            } catch {
                firstError = firstError ?? error
            }
            guard isCurrentActivation(userID, generation: activationGeneration),
                  studySurfaceRevision == presentationRevision
            else { return }
            if let firstError {
                markOutboxRetryNeeded(for: firstError)
                handleSyncError(
                    firstError,
                    for: userID,
                    activationGeneration: activationGeneration
                )
            }
        }
    }

    private func rollBackSessionTrackingForProgressionLock(
        eventID: String,
        card: StudyCard,
        userID: Int
    ) throws {
        try localCardRepository.markProgressionLocked(card, userID: userID)
        sessionCompletedCardIDs.remove(card.id)
        if let wasFailed = sessionFailureWasPresentByEventID.removeValue(forKey: eventID) {
            if wasFailed {
                sessionFailedCardIDs.insert(card.id)
            } else {
                sessionFailedCardIDs.remove(card.id)
            }
        }
        if let animatedCard = masteryAnimation?.card,
           StudyCardIdentity.matches(animatedCard, card)
        {
            masteryAnimation = nil
        }
        apply((try? reviewOutbox.pendingState()) ?? PendingReviewState())
    }

    func undoReview(eventID: String, cardBefore: StudyCard) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let presentationRevision = studySurfaceRevision
        let undoingPresentedLesson = lessonSessionIsPresented
        await reviewOutbox.waitForCurrentFlush()
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        guard try !cardOutbox.hasPendingDelete(for: cardBefore) else {
            throw DeletedCardUndoError()
        }
        if try reviewOutbox.stageRemoval(eventID: eventID) {
            reviewOutboxRevision &+= 1
            // The view may hold a pre-reconciliation snapshot. For a locally
            // pending undo, preserve the latest local presentation while
            // restoring the scheduling state captured before the review.
            let restoredCard = try restoreReviewedCard(
                cardBefore,
                preservingLocalPresentation: true,
                presentationRevision: presentationRevision,
                undoingPresentedLesson: undoingPresentedLesson
            )
            apply(try reviewOutbox.pendingState())
            restoreSessionFailure(
                for: restoredCard.id,
                before: eventID,
                presentationRevision: presentationRevision
            )
            return
        }

        let response: UndoStudyReviewResponse = try await api.request(
            "/api/study/reviews/undo",
            method: "POST",
            body: UndoStudyReviewRequest(
                reviewLogId: eventID.lowercased(),
                timeZone: TimeZone.current.identifier,
                currentOverview: overview
            )
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        let restoredCard = try restoreReviewedCard(
            response.card,
            presentationRevision: presentationRevision,
            undoingPresentedLesson: undoingPresentedLesson
        )
        let reviewTimeBudgetMinutes = resolvedReviewTimeBudget(from: response.overview)
        setOverview(response.overview.updatingReviewTimeBudget(
            to: reviewTimeBudgetMinutes,
            fallbackJLPTMastery: overview?.jlptMastery
        ))
        apply(try reviewOutbox.pendingState())
        restoreSessionFailure(
            for: restoredCard.id,
            before: eventID,
            presentationRevision: presentationRevision
        )
    }

    func resolvedReviewTimeBudget(from responseOverview: StudyOverview? = nil) -> Int {
        StudySettingsPolicy.resolvedReviewTimeBudget(
            responseOverview: responseOverview,
            settings: studySettings,
            currentOverview: overview
        )
    }

    private func restoreSessionFailure(
        for cardID: String,
        before eventID: String,
        presentationRevision: Int
    ) {
        guard let wasPresent = sessionFailureWasPresentByEventID.removeValue(forKey: eventID) else {
            return
        }
        guard presentationRevision == studySurfaceRevision else { return }
        if wasPresent {
            sessionFailedCardIDs.insert(cardID)
        } else {
            sessionFailedCardIDs.remove(cardID)
        }
    }

}
