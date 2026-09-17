import Foundation
import SwiftData

@MainActor
struct StudyOfflineCardReconciler {
    struct Change {
        let identifiers: Set<String>
        let card: StudyCard?

        func applying(to cards: [StudyCard], studyDate: Date? = nil) -> [StudyCard] {
            cards.compactMap { existing in
                guard StudyCardIdentity.matches(existing, any: identifiers) else { return existing }
                guard let card else { return nil }
                if let studyDate, !card.isEligibleForOfflineStudy(at: studyDate) { return nil }
                return card
            }
        }
    }

    let api: APIClient
    let context: ModelContext

    func reconcile(
        confirmedCards: [StudyCard],
        at snapshotDate: Date,
        userID: Int,
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
        for candidate in candidates {
            try requireCurrent(isCurrent)
            guard let record = try unmodifiedRecord(for: candidate, userID: userID) else { continue }
            let originalPayload = record.payload
            let serverCard = try await fetch(candidate)
            try requireCurrent(isCurrent)
            // A review, edit, action, or feed update can finish during the fetch.
            // Never overwrite newer local work, even if its outbox already drained.
            guard let current = try unmodifiedRecord(for: candidate, userID: userID),
                  current.payload == originalPayload
            else { continue }
            didReconcile(try apply(serverCard, to: current, previous: candidate))
        }
    }

    private func requireCurrent(_ isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }

    private func unmodifiedRecord(for card: StudyCard, userID: Int) throws -> LocalCardRecord? {
        let repository = StudyCardLocalRepository(context: context)
        guard let record = try repository.record(matching: card, userID: userID),
              record.locallyUpdatedAt == nil
        else { return nil }
        let pendingIdentifiers = Set(try context.fetch(
            FetchDescriptor<PendingMutation>(predicate: #Predicate { $0.userID == userID })
        ).map { $0.resourceID.lowercased() })
        guard !StudyCardIdentity.matches(card, any: pendingIdentifiers) else { return nil }
        return record
    }

    private func fetch(_ card: StudyCard) async throws -> StudyCard? {
        do {
            let serverCard: StudyCard = try await api.request(
                "/api/study/cards/\(card.reviewCardID)"
            )
            guard StudyCardIdentity.matches(serverCard, card) else {
                throw APIClientError.invalidResponse
            }
            return serverCard
        } catch APIClientError.rejected(status: 404, message: _) {
            return nil
        }
    }

    private func apply(
        _ serverCard: StudyCard?,
        to record: LocalCardRecord,
        previous: StudyCard
    ) throws -> Change {
        let resolved = serverCard?.resolvingProgressionMetadata(fallingBackTo: previous)
        let persisted = resolved.map {
            $0.replacingIdentity(id: record.id, syncId: $0.reviewCardID)
        }
        if let persisted {
            record.replacePayload(encoded: try StorageCodec.encoder.encode(persisted))
            record.serverUpdatedAt = persisted.updatedAt
            record.isInActiveSession = record.isInActiveSession
                && persisted.isEligibleForOfflineStudy(at: .now)
        } else {
            context.delete(record)
        }
        try context.save()
        return Change(identifiers: StudyCardIdentity.identifiers(for: previous), card: persisted)
    }
}
