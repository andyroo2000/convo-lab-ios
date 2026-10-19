import Foundation
import SwiftData

/// Commits small batches before yielding so foreground edits never share an
/// unfinished import transaction. Interrupted imports can resume as upserts.
@MainActor
final class StudyTimeHistoryImporter {
    private struct ProjectionPage {
        let sessions: [StudyActivitySession]
        let active: StudyTimeActiveSession?
        let count: Int
        let cursor: String?
    }

    private let context: ModelContext
    private let saver: any StudyTimeContextSaving
    private let batchSize: Int
    private let yieldControl: @MainActor () async -> Void

    init(
        context: ModelContext,
        saver: any StudyTimeContextSaving,
        batchSize: Int = 128,
        yieldControl: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) {
        precondition(batchSize > 0)
        self.context = context
        self.saver = saver
        self.batchSize = batchSize
        self.yieldControl = yieldControl
    }

    func mergeAndLoad(
        _ remote: [StudyActivitySession],
        userID: Int,
        canContinue: @escaping @MainActor () -> Bool
    ) async throws -> StudyTimeSessionMutationRepository.LoadedSessions {
        for offset in stride(from: 0, to: remote.count, by: batchSize) {
            try requireReady(canContinue)
            let end = min(offset + batchSize, remote.count)
            try mergeBatch(Array(remote[offset..<end]), userID: userID)
            await yieldControl()
        }
        return try await loadProjection(userID: userID, canContinue: canContinue)
    }

    private func requireReady(_ canContinue: () -> Bool) throws {
        // A calendar edit can suspend with an inserted local row. Do not save
        // or roll back another operation's uncommitted changes.
        guard !Task.isCancelled, canContinue(), !context.hasChanges else {
            throw CancellationError()
        }
    }

    private func mergeBatch(_ remote: [StudyActivitySession], userID: Int) throws {
        let identifiers = remote.map(\.clientSessionId)
        let existing = try context.fetch(FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate { $0.userID == userID && identifiers.contains($0.clientSessionID) }
        ))
        var records = Dictionary(existing.map { ($0.clientSessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for session in remote {
            if upsert(session, userID: userID, records: &records) { changed = true }
        }
        guard changed else { return }
        do {
            try saver.save()
        } catch {
            // Entry was clean and this batch contains no suspension points.
            // Earlier batches are already durable and must remain committed.
            context.rollback()
            throw error
        }
    }

    private func upsert(
        _ session: StudyActivitySession, userID: Int,
        records: inout [String: LocalStudyActivitySession]
    ) -> Bool {
        if let record = records[session.clientSessionId] {
            guard !record.isTombstone, !record.syncPending, record.session != session else { return false }
            record.apply(session)
        } else {
            let record = LocalStudyActivitySession(session: session, userID: userID)
            context.insert(record)
            records[session.clientSessionId] = record
        }
        return true
    }

    private func loadProjection(
        userID: Int, canContinue: @escaping @MainActor () -> Bool
    ) async throws -> StudyTimeSessionMutationRepository.LoadedSessions {
        var sessions: [StudyActivitySession] = []
        var active: StudyTimeActiveSession?
        var cursor: String?
        while true {
            try requireReady(canContinue)
            let page = try projectionPage(userID: userID, after: cursor)
            sessions.append(contentsOf: page.sessions)
            active = newer(active, page.active)
            guard page.count == batchSize else { break }
            cursor = page.cursor
            await yieldControl()
        }
        // Enumerate with the existing unique account/identifier index, then
        // sort value types off the main actor. Existing stores need no migration.
        let sorted = await Task.detached(priority: .utility) { [sessions] in
            sessions.sorted {
                if $0.startedAt == $1.startedAt { return $0.clientSessionId > $1.clientSessionId }
                return $0.startedAt > $1.startedAt
            }
        }.value
        try requireReady(canContinue)
        return .init(sessions: sorted, active: active)
    }

    private func projectionPage(userID: Int, after cursor: String?) throws -> ProjectionPage {
        var descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: projectionPredicate(userID: userID, after: cursor),
            sortBy: [SortDescriptor(\.clientSessionID, comparator: .lexical, order: .reverse)]
        )
        descriptor.fetchLimit = batchSize
        let records = try context.fetch(descriptor)
        return .init(sessions: records.compactMap(\.session),
                     active: records.reduce(nil) { newer($0, $1.activeSession) },
                     count: records.count,
                     cursor: records.last?.clientSessionID)
    }

    private func projectionPredicate(userID: Int, after cursor: String?)
        -> Predicate<LocalStudyActivitySession> {
        guard let cursor else { return #Predicate { $0.userID == userID } }
        return #Predicate { $0.userID == userID && $0.clientSessionID < cursor }
    }

    private func newer(_ first: StudyTimeActiveSession?, _ second: StudyTimeActiveSession?) -> StudyTimeActiveSession? {
        guard let first else { return second }
        guard let second else { return first }
        if first.startedAt == second.startedAt {
            return first.clientSessionID > second.clientSessionID ? first : second
        }
        return first.startedAt > second.startedAt ? first : second
    }
}
