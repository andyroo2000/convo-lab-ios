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
        didReconcile: ([Change]) -> Void
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
        didReconcile: ([Change]) -> Void
    ) async throws {
        let resolver = StudyOfflineCardResolver(api: api)
        let fetched = try await resolver.fetchBatch(batch.map(\.card))
        try requireCurrent(isCurrent)
        let confirmed = batch.compactMap { candidate -> Resolution? in
            guard let card = fetched.card(matching: StudyCardIdentity.identifiers(for: candidate.card))
            else { return nil }
            return Resolution(candidate: candidate, result: .success(card))
        }
        try apply(confirmed, userID: userID, now: now, didReconcile: didReconcile)
        let missing = batch.filter {
            fetched.card(matching: StudyCardIdentity.identifiers(for: $0.card)) == nil
        }
        // Missing batch entries require individual confirmation, including legacy IDs.
        for offset in stride(from: 0, to: missing.count, by: StudyOfflineCardResolver.individualConcurrency) {
            let pending = try pendingIdentifiers(userID: userID)
            let requests = try missing.dropFirst(offset).prefix(StudyOfflineCardResolver.individualConcurrency).filter {
                try unchangedRecord($0, userID: userID, pending: pending) != nil
            }
            let results = await resolver.fetchIndividually(requests.map(\.card))
            try requireCurrent(isCurrent)
            let resolved = results.map {
                Resolution(candidate: requests[$0.index], result: $0.result)
            }
            try apply(resolved, userID: userID, now: now, didReconcile: didReconcile)
        }
    }

    private struct Resolution {
        let candidate: Candidate
        let result: Result<StudyCard?, Error>
    }

    private func apply(
        _ resolved: [Resolution], userID: Int, now: () -> Date,
        didReconcile: ([Change]) -> Void
    ) throws {
        let pending = try pendingIdentifiers(userID: userID)
        var changes: [Change] = []
        // Publish saved progress even when another request or save in this group fails.
        defer { if !changes.isEmpty { didReconcile(changes) } }
        for resolution in resolved {
            guard case let .success(card) = resolution.result,
                  let record = try unchangedRecord(resolution.candidate, userID: userID, pending: pending)
            else { continue }
            changes.append(try apply(card, to: record, previous: resolution.candidate.card, at: now()))
        }
        for resolution in resolved {
            // Propagate network failures only after publishing the successful repairs.
            _ = try resolution.result.get()
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
