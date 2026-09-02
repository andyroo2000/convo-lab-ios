import Foundation
import SwiftData

extension StudyStore {
    func reloadFailedStudyChanges() {
        guard let userID = activeUserID else {
            failedStudyChanges = []
            return
        }
        let descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate { $0.userID == userID && $0.lastError != nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        failedStudyChanges = ((try? context.fetch(descriptor)) ?? [])
            .compactMap { $0.failedStudyChange() }
    }

    func retryFailedStudyChange(id: String) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        guard failedStudyChangeOperationIDs.insert(id).inserted else { return }
        defer {
            failedStudyChangeOperationIDs.remove(id)
        }
        let activationGeneration = accountActivationGeneration
        guard let mutation = try failedMutation(id: id, userID: userID),
              let kind = mutation.studyMutationKind
        else { return }
        guard mutation.failedStudyChange()?.isRetryable != false else { return }

        mutation.lastError = nil
        try context.save()
        reloadFailedStudyChanges()

        do {
            try await retryFailedMutation(kind)
        } catch {
            handleFailedMutationRetry(
                error,
                kind: kind,
                userID: userID,
                activationGeneration: activationGeneration
            )
            throw error
        }
        reloadFailedStudyChanges()
    }

    func discardFailedStudyChange(id: String) async throws {
        try requirePersistentWrites()
        guard let userID = activeUserID else { throw CancellationError() }
        let activationGeneration = accountActivationGeneration
        guard failedStudyChangeOperationIDs.insert(id).inserted else { return }
        defer { failedStudyChangeOperationIDs.remove(id) }
        guard let mutation = try failedMutation(id: id, userID: userID),
              let kind = mutation.studyMutationKind
        else { return }

        let resourceID = mutation.resourceID.lowercased()
        let canonicalCard = try await canonicalCardForDiscard(
            mutation,
            kind: kind,
            userID: userID
        )
        guard isCurrentActivation(userID, generation: activationGeneration) else {
            throw CancellationError()
        }
        guard let currentMutation = try failedMutation(id: id, userID: userID),
              currentMutation.studyMutationKind == kind
        else { return }
        if shouldDiscardLocalCardActivity(kind: kind, canonicalCard: canonicalCard) {
            // A review/update against a card the server rejected cannot succeed on
            // its own. The same is true when an edited server card no longer exists.
            try discardLocalCardActivity(userID: userID, resourceID: resourceID)
        } else {
            try discardMutation(
                currentMutation,
                kind: kind,
                resourceID: resourceID,
                canonicalCard: canonicalCard,
                userID: userID
            )
        }
        try context.save()
        restorePendingReviewState()
        loadLocalCards(userID: userID)
        loadLibraryCards(userID: userID)
        reloadFailedStudyChanges()

        // Discarding removes the row that intentionally blocked inbound data.
        // Reconcile immediately when online; ordinary sync will retry later if not.
        await synchronize()
    }

    private func retryFailedMutation(_ kind: StudyMutationKind) async throws {
        switch kind {
        case .cardCreate, .cardUpdate, .cardDelete:
            try await flushCardOutbox()
        case .cardAction, .review:
            try await flushSchedulingOutboxes()
            restorePendingReviewState()
        }
    }

    private func handleFailedMutationRetry(
        _ error: any Error,
        kind: StudyMutationKind,
        userID: Int,
        activationGeneration: Int
    ) {
        if kind == .review {
            restorePendingReviewState()
        }
        markOutboxRetryNeeded(for: error)
        handleSyncError(
            error,
            for: userID,
            activationGeneration: activationGeneration
        )
        reloadFailedStudyChanges()
    }

    private func canonicalCardForDiscard(
        _ mutation: PendingMutation,
        kind: StudyMutationKind,
        userID: Int
    ) async throws -> StudyCard? {
        let needsCanonicalCard = switch kind {
        case .cardDelete, .cardUpdate, .cardAction, .review: true
        case .cardCreate: false
        }
        guard needsCanonicalCard else { return nil }
        let lookupID = if kind == .review {
            try canonicalReviewCardID(for: mutation, userID: userID)
        } else {
            mutation.resourceID
        }
        guard let lookupID else { return nil }
        return try await fetchCanonicalCard(id: lookupID)
    }

    private func shouldDiscardLocalCardActivity(
        kind: StudyMutationKind,
        canonicalCard: StudyCard?
    ) -> Bool {
        switch kind {
        case .cardCreate:
            true
        case .cardUpdate, .cardAction, .review:
            canonicalCard == nil
        case .cardDelete:
            false
        }
    }

    private func discardMutation(
        _ mutation: PendingMutation,
        kind: StudyMutationKind,
        resourceID: String,
        canonicalCard: StudyCard?,
        userID: Int
    ) throws {
        context.delete(mutation)
        let remaining = try hasRemainingStudyMutation(
            excluding: mutation.id,
            resourceID: resourceID,
            userID: userID
        )
        guard !remaining else { return }

        switch kind {
        case .cardUpdate, .cardAction:
            try localRecords(userID: userID, matching: resourceID).forEach {
                $0.locallyUpdatedAt = nil
            }
        case .cardCreate, .cardDelete, .review:
            break
        }
        // Any remaining card write or review owns the optimistic replica.
        // Restoring a server snapshot here would clobber that newer local work.
        if let canonicalCard {
            try upsertLocalCard(
                canonicalCard,
                markedDirty: false,
                serverUpdatedAt: canonicalCard.updatedAt
            )
        }
    }

    private func hasRemainingStudyMutation(
        excluding mutationID: String,
        resourceID: String,
        userID: Int
    ) throws -> Bool {
        try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.userID == userID }
            )
        ).contains { mutation in
            guard mutation.id != mutationID else { return false }
            guard mutation.resourceID.lowercased() == resourceID else { return false }
            return mutation.studyMutationKind != nil
        }
    }

    private func canonicalReviewCardID(
        for mutation: PendingMutation,
        userID: Int
    ) throws -> String? {
        let directCandidates = [
            reviewOutbox.cardID(for: mutation),
            mutation.resourceID,
        ]
        if let identifier = directCandidates.compactMap({ $0 }).first(where: {
            ClientIdentifier.isULID($0)
        }) {
            return identifier.lowercased()
        }

        let resourceID = mutation.resourceID.lowercased()
        for record in try localRecords(userID: userID, matching: resourceID) {
            let candidates = [
                record.syncID,
                (try? StorageCodec.decoder.decode(
                    StudyCard.self,
                    from: record.payload
                ))?.reviewCardID,
            ]
            if let identifier = candidates.compactMap({ $0 }).first(where: {
                ClientIdentifier.isULID($0)
            }) {
                return identifier.lowercased()
            }
        }
        return nil
    }

    private func failedMutation(id: String, userID: Int) throws -> PendingMutation? {
        var descriptor = FetchDescriptor<PendingMutation>(
            predicate: #Predicate {
                $0.userID == userID && $0.id == id && $0.lastError != nil
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func discardLocalCardActivity(userID: Int, resourceID: String) throws {
        let related = try context.fetch(
            FetchDescriptor<PendingMutation>(
                predicate: #Predicate { $0.userID == userID }
            )
        ).filter { $0.resourceID.lowercased() == resourceID }
        related.forEach(context.delete)
        for record in try localRecords(userID: userID, matching: resourceID) {
            context.delete(record)
        }
    }

    private func localRecords(
        userID: Int,
        matching normalizedResourceID: String
    ) throws -> [LocalCardRecord] {
        try context.fetch(
            FetchDescriptor<LocalCardRecord>(
                predicate: #Predicate { $0.userID == userID }
            )
        ).filter { record in
            if record.id.lowercased() == normalizedResourceID
                || record.syncID.lowercased() == normalizedResourceID
            {
                return true
            }
            guard let card = try? StorageCodec.decoder.decode(
                StudyCard.self,
                from: record.payload
            ) else { return false }
            return StudyCardIdentity.matches(card, any: [normalizedResourceID])
        }
    }
}
