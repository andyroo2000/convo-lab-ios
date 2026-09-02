import Foundation

extension StudyStore {
    func resolvePitchAccent(for card: StudyCard) async {
        guard let resolution = beginPitchAccentResolution(for: card) else { return }
        defer { finishPitchAccentResolution(resolution.token) }

        do {
            guard let updatedCard = try await resolvedPitchAccentCard(
                for: card,
                resolution: resolution
            ), activeUserID == resolution.userID else { return }
            publishPitchAccentResolution(updatedCard, replacing: card)
        } catch {
            // Pitch accent is optional enrichment. Offline and unresolved cards
            // remain fully studyable and can retry on a later reveal.
        }
    }

    private func beginPitchAccentResolution(
        for card: StudyCard
    ) -> (userID: Int, token: UUID)? {
        guard
            let userID = activeUserID,
            card.answer["pitchAccent"]?["status"]?.stringValue == nil,
            pitchAccentResolutionTokens[card.id] == nil
        else {
            return nil
        }
        let token = UUID()
        pitchAccentResolutionTokens[card.id] = token
        resolvingPitchAccentCardIDs.insert(card.id)
        return (userID, token)
    }

    private func resolvedPitchAccentCard(
        for card: StudyCard,
        resolution: (userID: Int, token: UUID)
    ) async throws -> StudyCard? {
        try await pitchAccentService.resolve(
            card,
            prepare: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.flushCardOutbox()
            },
            onCardPrepared: { [weak self] preparedCard in
                self?.trackPitchAccentResolution(
                    resolution,
                    for: preparedCard
                ) ?? false
            },
            hasPendingDelete: { [weak self] resolvedCard in
                guard let self else { throw CancellationError() }
                return try self.cardOutbox.hasPendingDelete(for: resolvedCard)
            }
        )
    }

    private func trackPitchAccentResolution(
        _ resolution: (userID: Int, token: UUID),
        for card: StudyCard
    ) -> Bool {
        guard activeUserID == resolution.userID else { return false }
        if let existingToken = pitchAccentResolutionTokens[card.id] {
            return existingToken == resolution.token
        }
        pitchAccentResolutionTokens[card.id] = resolution.token
        resolvingPitchAccentCardIDs.insert(card.id)
        return true
    }

    private func finishPitchAccentResolution(_ token: UUID) {
        let trackedIDs = pitchAccentResolutionTokens.compactMap { id, trackedToken in
            trackedToken == token ? id : nil
        }
        for id in trackedIDs {
            pitchAccentResolutionTokens.removeValue(forKey: id)
            resolvingPitchAccentCardIDs.remove(id)
        }
    }

    private func publishPitchAccentResolution(
        _ updatedCard: StudyCard,
        replacing card: StudyCard
    ) {
        let identifiers = StudyCardIdentity.identifiers(for: card).union(
            StudyCardIdentity.identifiers(for: updatedCard)
        )
        cards = cards.map {
            StudyCardIdentity.matches($0, any: identifiers) ? updatedCard : $0
        }
        libraryCards = libraryCards.map {
            StudyCardIdentity.matches($0, any: identifiers) ? updatedCard : $0
        }
        allCards = allCards.map {
            StudyCardIdentity.matches($0, any: identifiers) ? updatedCard : $0
        }
    }
}
