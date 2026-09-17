import Foundation
import SwiftData

@MainActor
struct StudyOfflineCardReconciler {
    struct Change {
        let identifiers: Set<String>
        let card: StudyCard?
        let evaluatedAt: Date

        func applying(to cards: [StudyCard], studyDate: Date? = nil) -> [StudyCard] {
            cards.compactMap { existing in
                guard StudyCardIdentity.matches(existing, any: identifiers) else { return existing }
                guard let card else { return nil }
                if let studyDate, !card.isEligibleForOfflineStudy(at: studyDate) { return nil }
                return card
            }
        }
    }

    private struct Candidate {
        let card: StudyCard
        let payload: Data
    }

    let api: APIClient
    let context: ModelContext

    func reconcile(
        confirmedCards: [StudyCard],
        at snapshotDate: Date,
        userID: Int,
        now: () -> Date = { .now },
        isCurrent: () -> Bool,
        didReconcile: (Change) -> Void
    ) async throws {
        let repository = StudyCardLocalRepository(context: context)
        let confirmedIdentifiers = confirmedCards.reduce(into: Set<String>()) {
            $0.formUnion(StudyCardIdentity.identifiers(for: $1))
        }
        let candidates = try repository.libraryCards(userID: userID).filter {
            $0.isEligibleForOfflineStudy(at: snapshotDate)
                && !StudyCardIdentity.matches($0, any: confirmedIdentifiers)
        }
        for offset in stride(from: 0, to: candidates.count, by: 50) {
            try requireCurrent(isCurrent)
            let pending = try pendingIdentifiers(userID: userID)
            let batch = try candidates.dropFirst(offset).prefix(50).compactMap { card -> Candidate? in
                guard let record = try unmodifiedRecord(for: card, userID: userID, pending: pending)
                else { return nil }
                return Candidate(card: card, payload: record.payload)
            }
            try await reconcile(batch, userID: userID, now: now,
                                isCurrent: isCurrent, didReconcile: didReconcile)
        }
    }

    private func reconcile(
        _ batch: [Candidate],
        userID: Int,
        now: () -> Date,
        isCurrent: () -> Bool,
        didReconcile: (Change) -> Void
    ) async throws {
        let resolver = StudyOfflineCardResolver(api: api)
        let fetched = try await resolver.fetchBatch(batch.map(\.card))
        try requireCurrent(isCurrent)
        var pending = try pendingIdentifiers(userID: userID)
        for candidate in batch {
            guard try unchangedRecord(candidate, userID: userID, pending: pending) != nil
            else { continue }
            var serverCard = fetched.card(matching: StudyCardIdentity.identifiers(for: candidate.card))
            if serverCard == nil {
                // Batch omissions are not proof of deletion. Confirm with an individual lookup.
                serverCard = try await resolver.fetch(candidate.card)
                try requireCurrent(isCurrent)
                pending = try pendingIdentifiers(userID: userID)
            }
            // A review, edit, action, or feed update can finish during either request.
            // Preserve newer local work even if its outbox already drained.
            guard let record = try unchangedRecord(candidate, userID: userID, pending: pending)
            else { continue }
            didReconcile(try apply(serverCard, to: record, previous: candidate.card, at: now()))
        }
    }

    private func unchangedRecord(
        _ candidate: Candidate, userID: Int, pending: Set<String>
    ) throws -> LocalCardRecord? {
        guard let record = try unmodifiedRecord(for: candidate.card, userID: userID, pending: pending),
              record.payload == candidate.payload
        else { return nil }
        return record
    }

    private func requireCurrent(_ isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }

    private func unmodifiedRecord(
        for card: StudyCard, userID: Int, pending: Set<String>
    ) throws -> LocalCardRecord? {
        guard !StudyCardIdentity.matches(card, any: pending) else { return nil }
        let repository = StudyCardLocalRepository(context: context)
        guard let record = try repository.record(matching: card, userID: userID),
              record.locallyUpdatedAt == nil
        else { return nil }
        return record
    }

    private func pendingIdentifiers(userID: Int) throws -> Set<String> {
        Set(try context.fetch(
            FetchDescriptor<PendingMutation>(predicate: #Predicate { $0.userID == userID })
        ).map { $0.resourceID.lowercased() })
    }

    private func apply(
        _ serverCard: StudyCard?,
        to record: LocalCardRecord,
        previous: StudyCard,
        at date: Date
    ) throws -> Change {
        let resolved = serverCard?.resolvingProgressionMetadata(fallingBackTo: previous)
        let persisted = resolved.map {
            $0.replacingIdentity(id: record.id, syncId: $0.reviewCardID)
        }
        if let persisted {
            record.replacePayload(encoded: try StorageCodec.encoder.encode(persisted))
            record.serverUpdatedAt = persisted.updatedAt
            record.isInActiveSession = record.isInActiveSession
                && persisted.isEligibleForOfflineStudy(at: date)
        } else {
            context.delete(record)
        }
        try context.save()
        return Change(identifiers: StudyCardIdentity.identifiers(for: previous),
                      card: persisted, evaluatedAt: date)
    }
}
