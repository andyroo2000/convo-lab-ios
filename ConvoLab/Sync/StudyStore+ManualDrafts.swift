import Foundation

extension StudyStore {
    var manualDrafts: [StudyManualCardDraft] { manualDraftOutbox.drafts }

    var pendingManualDraftCreates: [CreateStudyManualCardDraftRequest] {
        _ = manualDraftOutboxRevision
        return manualDraftOutbox.pendingCreateRequests()
    }

    func refreshManualDrafts() async throws {
        try await manualDraftOutbox.refresh()
        manualDraftsRefreshedAt = .now
        persistManualDraftSnapshot()
    }

    func refreshManualDraftsIfNeeded(maxAge: TimeInterval = 60) async throws {
        guard !isFresh(manualDraftsRefreshedAt, maxAge: maxAge) else { return }
        try await refreshManualDrafts()
    }

    @discardableResult
    func queueManualDraft(
        creationKind: StudyCardCreationKind,
        draft: StudyCardDraft,
        id: String = ClientIdentifier.ulid()
    ) async throws -> StudyManualCardDraft {
        defer { manualDraftOutboxRevision &+= 1 }
        try requirePersistentWrites()
        guard activeUserID != nil else { throw CancellationError() }
        let request = CreateStudyManualCardDraftRequest(
            id: id,
            creationKind: creationKind,
            cardType: creationKind.cardType.rawValue,
            prompt: creationKind == .audioRecognition ? .object([:]) : draft.prompt(),
            answer: draft.answer(),
            imagePlacement: draft.imagePlacement,
            imagePrompt: draft.imagePrompt.nilIfTrimmedEmpty
        )
        let created = try await manualDraftOutbox.queueCreate(request)
        persistManualDraftSnapshot()
        return created
    }

    @discardableResult
    func updateManualDraft(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue? = nil,
        previewAudioRole: String? = nil,
        previewImage: JSONValue? = nil
    ) async throws -> StudyManualCardDraft {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let content = manualDraftContent(
            serverDraft: serverDraft,
            draft: draft,
            previewAudio: previewAudio,
            previewAudioRole: previewAudioRole,
            previewImage: previewImage
        )
        let resolvedPreviewAudio = previewAudio ?? serverDraft.previewAudio
        let resolvedPreviewAudioRole = previewAudio == nil
            ? serverDraft.previewAudioRole
            : previewAudioRole
        let resolvedPreviewImage = previewImage ?? serverDraft.previewImage
        let request = UpdateStudyManualCardDraftRequest(
            prompt: content.prompt,
            answer: content.answer,
            imagePlacement: draft.imagePlacement,
            imagePrompt: draft.imagePrompt.nilIfTrimmedEmpty,
            previewAudio: resolvedPreviewAudio ?? .null,
            previewAudioRole: resolvedPreviewAudioRole.map(JSONValue.string) ?? .null,
            previewImage: resolvedPreviewImage ?? .null
        )
        let updated: StudyManualCardDraft = try await api.request(
            "/api/study/card-drafts/\(serverDraft.id)",
            method: "PATCH",
            body: request
        )
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        manualDraftOutbox.replace(updated)
        persistManualDraftSnapshot()
        return updated
    }

    func generateManualDraftPreviewAudio(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewImage: JSONValue?
    ) async throws -> DraftPreviewAudioResult {
        try await recordingGeneration {
            guard let userID = activeUserID else { throw CancellationError() }
            let activationGeneration = accountActivationGeneration
            let updated = try await updateManualDraft(
                serverDraft,
                draft: draft,
                previewImage: previewImage
            )
            let response: StudyCardDraftPreviewAudioResponse = try await api.request(
                "/api/study/card-drafts/\(updated.id)/preview-audio",
                method: "POST",
                timeout: 180
            )
            guard
                isCurrentActivation(
                    userID,
                    generation: activationGeneration
                )
            else { throw CancellationError() }
            let refreshed = try await fetchManualDraft(id: updated.id)
            let localURL: URL?
            if let remoteURL = response.previewAudio?.mediaURLs.first {
                localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
            } else {
                localURL = nil
            }
            guard
                isCurrentActivation(
                    userID,
                    generation: activationGeneration
                )
            else { throw CancellationError() }
            return DraftPreviewAudioResult(draft: refreshed, localURL: localURL)
        }
    }

    func generateManualDraftPreviewImage(
        _ serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue?,
        previewAudioRole: String?
    ) async throws -> DraftPreviewImageResult {
        try await recordingGeneration {
            guard let userID = activeUserID else { throw CancellationError() }
            let activationGeneration = accountActivationGeneration
            let updated = try await updateManualDraft(
                serverDraft,
                draft: draft,
                previewAudio: previewAudio,
                previewAudioRole: previewAudioRole
            )
            let response: StudyCardDraftImageResponse = try await api.request(
                "/api/study/card-drafts/\(updated.id)/preview-image",
                method: "POST",
                timeout: 180
            )
            guard
                isCurrentActivation(
                    userID,
                    generation: activationGeneration
                )
            else { throw CancellationError() }
            guard let remoteURL = response.previewImage.mediaURLs.first else {
                throw MissingGeneratedCardImageError()
            }
            let localURL = try await mediaCache.refresh(remoteURL, category: "active-study")
            guard
                isCurrentActivation(
                    userID,
                    generation: activationGeneration
                )
            else { throw CancellationError() }
            let refreshed = try await fetchManualDraft(id: updated.id)
            return DraftPreviewImageResult(draft: refreshed, localURL: localURL)
        }
    }

    func createCard(
        from serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue?,
        previewAudioRole: String?,
        previewImage: JSONValue?
    ) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        let recoveryState = manualDraftOutbox.recoveryState(for: serverDraft.id)
        let shouldUpdateDraft = recoveryState == .none || recoveryState == .rejected
        let updated = if shouldUpdateDraft {
            try await updateManualDraft(
                serverDraft,
                draft: draft,
                previewAudio: previewAudio,
                previewAudioRole: previewAudioRole,
                previewImage: previewImage
            )
        } else {
            serverDraft
        }
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        try await manualDraftOutbox.commit(
            draftID: updated.id,
            onCommittedCard: manualDraftCommitHandler(
                userID: userID,
                activationGeneration: activationGeneration
            )
        )
        persistManualDraftSnapshot()
    }

    func deleteManualDraft(_ serverDraft: StudyManualCardDraft) async throws {
        try requirePersistentWrites()
        try await manualDraftOutbox.deleteDraft(id: serverDraft.id)
        persistManualDraftSnapshot()
    }

    func hasPendingDraftCommit(for draftID: String) -> Bool {
        manualDraftOutbox.hasPendingCommit(for: draftID)
    }

    func draftCommitRecoveryState(for draftID: String) -> DraftCommitRecoveryState {
        manualDraftOutbox.recoveryState(for: draftID)
    }

    private func fetchManualDraft(id: String) async throws -> StudyManualCardDraft {
        let draft = try await manualDraftOutbox.fetch(id: id)
        persistManualDraftSnapshot()
        return draft
    }

    func retryPendingDraftCreates() async throws {
        defer { manualDraftOutboxRevision &+= 1 }
        defer { persistManualDraftSnapshot() }
        try requirePersistentWrites()
        try await manualDraftOutbox.retryPendingCreates()
    }

    func retryPendingDraftMutations(
        userID: Int,
        activationGeneration: Int
    ) async throws {
        defer { manualDraftOutboxRevision &+= 1 }
        defer { persistManualDraftSnapshot() }
        try await manualDraftOutbox.retryPendingMutations(
            onCommittedCard: manualDraftCommitHandler(
                userID: userID,
                activationGeneration: activationGeneration
            )
        )
    }

    func retryPendingDraftCommits() async throws {
        defer { persistManualDraftSnapshot() }
        try requirePersistentWrites()
        guard let userID = activeUserID else { return }
        let activationGeneration = accountActivationGeneration
        try await manualDraftOutbox.retryPendingCommits(
            onCommittedCard: manualDraftCommitHandler(
                userID: userID,
                activationGeneration: activationGeneration
            )
        )
    }

    private func manualDraftCommitHandler(
        userID: Int,
        activationGeneration: Int
    ) -> (StudyCard) async throws -> Void {
        { [weak self] card in
            guard let self, self.isCurrentActivation(
                userID,
                generation: activationGeneration
            ) else {
                throw CancellationError()
            }
            try await self.applyCommittedManualDraftCard(
                card,
                userID: userID,
                activationGeneration: activationGeneration
            )
        }
    }

    private func manualDraftContent(
        serverDraft: StudyManualCardDraft,
        draft: StudyCardDraft,
        previewAudio: JSONValue?,
        previewAudioRole: String?,
        previewImage: JSONValue?
    ) -> (prompt: JSONValue, answer: JSONValue) {
        let base = (
            prompt: draft.prompt(merging: serverDraft.prompt),
            answer: draft.answer(merging: serverDraft.answer)
        )
        let withAudio = addingPreviewAudio(
            previewAudio,
            role: previewAudioRole,
            to: base
        )
        return addingPreviewImage(
            previewImage,
            placement: draft.imagePlacement,
            to: withAudio
        )
    }

    private func addingPreviewAudio(
        _ previewAudio: JSONValue?,
        role: String?,
        to content: (prompt: JSONValue, answer: JSONValue)
    ) -> (prompt: JSONValue, answer: JSONValue) {
        guard let previewAudio else { return content }
        if role == "prompt" {
            return (
                content.prompt.replacingObjectValues(["cueAudio": previewAudio]),
                content.answer.replacingObjectValues(["answerAudio": previewAudio])
            )
        }
        guard role == "answer" else { return content }
        return (
            content.prompt,
            content.answer.replacingObjectValues(["answerAudio": previewAudio])
        )
    }

    private func addingPreviewImage(
        _ previewImage: JSONValue?,
        placement: StudyCardDraft.ImagePlacement,
        to content: (prompt: JSONValue, answer: JSONValue)
    ) -> (prompt: JSONValue, answer: JSONValue) {
        guard let previewImage else { return content }
        let prompt = placement.includesPrompt
            ? content.prompt.replacingObjectValues(["cueImage": previewImage])
            : content.prompt
        let answer = placement.includesAnswer
            ? content.answer.replacingObjectValues(["answerImage": previewImage])
            : content.answer
        return (prompt, answer)
    }

    private func recordingGeneration<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        let diagnosticInterval = diagnostics.begin(.generation)
        var diagnosticOutcome: NativeDiagnosticOutcome = .failed
        defer {
            diagnostics.end(
                diagnosticInterval,
                outcome: diagnosticOutcome
            )
        }
        do {
            let result = try await operation()
            diagnosticOutcome = .succeeded
            return result
        } catch {
            diagnosticOutcome = .classifying(error)
            throw error
        }
    }

    private func applyCommittedManualDraftCard(
        _ card: StudyCard,
        userID: Int,
        activationGeneration: Int
    ) async throws {
        guard isCurrentActivation(
            userID,
            generation: activationGeneration
        ) else { throw CancellationError() }
        try upsertLocalCard(card, markedDirty: false)
        if !lessonSessionIsPresented {
            cards.removeAll { $0.id.lowercased() == card.id.lowercased() }
            cards.append(card)
            cards = StudySessionPolicy.offlineOrderedCards(cards)
        }
        libraryCards.removeAll { $0.id.lowercased() == card.id.lowercased() }
        libraryCards.append(card)
        upsertAllCardsPresentation(card, addToLearningItemsIfMissing: true)
        try context.save()
        await mediaCache.prepare(urls: card.mediaURLs, category: "active-study")
    }

    // Internal so concurrency tests can model a completed local mutation while
    // an older list request is still in flight.
    func replaceManualDraft(_ draft: StudyManualCardDraft) {
        manualDraftOutbox.replace(draft)
        persistManualDraftSnapshot()
    }
}
