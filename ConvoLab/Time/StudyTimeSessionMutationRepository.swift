import Foundation
import SwiftData

struct StudyTimeActiveSession: Equatable {
    let clientSessionID: String
    let category: StudyActivityCategory
    let activity: StudyActivityKind
    let source: StudyActivitySource
    let name: String?
    let startedAt: Date
    var cardsCreated: Int
}

enum StudyTimeStorageWriteOperation: Equatable {
    case start(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String?,
        replacingSessionID: String?
    )
    case finish(clientSessionID: String)
    case addCreatedCards(clientSessionID: String, count: Int)
    case recordCompleted(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String?,
        startedAt: Date,
        duration: TimeInterval
    )
    case update(clientSessionID: String)
    case delete(clientSessionID: String)
}

enum StudyTimeEditableSessionProjection {
    static func upserting(
        _ session: StudyActivitySession,
        in sessions: [StudyActivitySession]
    ) -> [StudyActivitySession] {
        guard session.isEditable else { return sessions }
        return sortedUnique(sessions + [session])
    }

    static func removing(
        clientSessionID: String,
        from sessions: [StudyActivitySession]
    ) -> [StudyActivitySession] {
        sessions.filter { $0.clientSessionId != clientSessionID }
    }

    static func sortedUnique(
        _ candidates: [StudyActivitySession]
    ) -> [StudyActivitySession] {
        var byID: [String: StudyActivitySession] = [:]
        for session in candidates where session.isEditable {
            byID[session.clientSessionId] = session
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.clientSessionId > rhs.clientSessionId
            }
            return lhs.startedAt > rhs.startedAt
        }
    }
}

protocol StudyTimeContextSaving: AnyObject {
    func save() throws
}

private final class ModelContextStudyTimeSaver: StudyTimeContextSaving {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save() throws {
        try context.save()
    }
}

enum StudyTimeSessionMutationError: LocalizedError {
    case readOnlySession
    case calendarEventUnavailable
    case sessionUnavailable
    case accountUnavailable

    var errorDescription: String? {
        switch self {
        case .readOnlySession:
            "Automatically or externally recorded study time cannot be changed."
        case .calendarEventUnavailable:
            "The linked calendar event is not available on this device."
        case .sessionUnavailable:
            "This study entry is no longer available. Refresh and try again."
        case .accountUnavailable:
            "Sign in before recording study time."
        }
    }
}

struct StudyTimeMutationPersistenceError: LocalizedError {
    let underlying: any Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

@MainActor
final class StudyTimeSessionMutationRepository {
    struct LoadedSessions {
        let sessions: [StudyActivitySession]
        let active: StudyTimeActiveSession?
    }

    struct StartResult {
        let active: StudyTimeActiveSession
        let completedPreviousSession: Bool
    }

    struct CompletedMutation {
        let session: StudyActivitySession?
        let calendarWarning: String?
    }

    struct PushResult {
        let failures: [String]
        let becameStale: Bool
    }

    private let api: APIClient
    private let context: ModelContext
    private let storageMode: StorageMode
    private let contextSaver: any StudyTimeContextSaving
    private let calendar: any StudyCalendarProviding

    init(
        api: APIClient,
        context: ModelContext,
        storageMode: StorageMode,
        contextSaver: (any StudyTimeContextSaving)?,
        calendar: (any StudyCalendarProviding)?
    ) {
        self.api = api
        self.context = context
        self.storageMode = storageMode
        self.contextSaver = contextSaver ?? ModelContextStudyTimeSaver(context: context)
        self.calendar = calendar ?? LiveStudyCalendar()
    }

    func requirePersistentWrites() throws {
        guard storageMode == .persistent else {
            throw StorageWriteUnavailableError(domain: .studyTime)
        }
    }

    func reclassifyLocalSessions(
        userID: Int,
        categoryForActivity: (StudyActivityKind) -> StudyActivityCategory
    ) throws {
        let records = try context.fetch(FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate { $0.userID == userID }
        ))
        var changed = false
        for record in records {
            guard let activity = StudyActivityKind(rawValue: record.activity) else { continue }
            let category = categoryForActivity(activity).rawValue
            guard record.category != category else { continue }
            record.category = category
            changed = true
        }
        if changed {
            try contextSaver.save()
        }
    }

    func start(
        replacing current: StudyTimeActiveSession?,
        activity: StudyActivityKind,
        category: StudyActivityCategory,
        source: StudyActivitySource,
        name: String?,
        at date: Date,
        userID: Int
    ) throws -> StartResult {
        if let current {
            guard let record = record(
                clientSessionID: current.clientSessionID,
                userID: userID
            ) else {
                throw StudyTimeSessionMutationError.sessionUnavailable
            }
            complete(record, from: current, at: date)
        }

        let session = StudyTimeActiveSession(
            clientSessionID: UUID().uuidString.lowercased(),
            category: category,
            activity: activity,
            source: source,
            name: name,
            startedAt: date,
            cardsCreated: 0
        )
        context.insert(LocalStudyActivitySession(active: session, userID: userID))
        do {
            try contextSaver.save()
            return StartResult(
                active: session,
                completedPreviousSession: current != nil
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    func addCreatedCards(
        _ count: Int,
        to current: StudyTimeActiveSession,
        userID: Int
    ) throws -> StudyTimeActiveSession {
        guard let record = record(
            clientSessionID: current.clientSessionID,
            userID: userID
        ) else {
            throw StudyTimeSessionMutationError.sessionUnavailable
        }
        var updated = current
        updated.cardsCreated += count
        record.cardsCreated = updated.cardsCreated
        do {
            try contextSaver.save()
            return updated
        } catch {
            context.rollback()
            throw error
        }
    }

    func finish(
        _ current: StudyTimeActiveSession,
        at date: Date,
        userID: Int
    ) throws -> StudyActivitySession? {
        guard let record = record(
            clientSessionID: current.clientSessionID,
            userID: userID
        ) else {
            throw StudyTimeSessionMutationError.sessionUnavailable
        }
        complete(record, from: current, at: date)
        do {
            try contextSaver.save()
            return record.session
        } catch {
            context.rollback()
            throw error
        }
    }

    func recordCompleted(
        activity: StudyActivityKind,
        category: StudyActivityCategory,
        source: StudyActivitySource,
        name: String?,
        startedAt: Date,
        duration: TimeInterval,
        addToCalendar: Bool,
        clientSessionID: String?,
        userID: Int
    ) async throws -> CompletedMutation {
        if let clientSessionID,
           let existing = recordIncludingTombstones(
               clientSessionID: clientSessionID,
               userID: userID
           )
        {
            return CompletedMutation(session: existing.session, calendarWarning: nil)
        }
        let boundedDuration = max(0, min(duration, 86_400))
        let endedAt = startedAt.addingTimeInterval(boundedDuration)
        var effectiveSource = source
        var calendarEventIdentifier: String?
        var calendarWarning: String?
        if addToCalendar {
            do {
                calendarEventIdentifier = try await calendar.addEvent(
                    title: name ?? activity.title,
                    start: startedAt,
                    end: endedAt
                )
                effectiveSource = .calendar
            } catch {
                effectiveSource = .manual
                calendarWarning = error.localizedDescription
            }
        }
        let session = StudyTimeActiveSession(
            clientSessionID: clientSessionID ?? UUID().uuidString.lowercased(),
            category: category,
            activity: activity,
            source: effectiveSource,
            name: name,
            startedAt: startedAt,
            cardsCreated: 0
        )
        let record = LocalStudyActivitySession(active: session, userID: userID)
        record.calendarEventIdentifier = calendarEventIdentifier
        context.insert(record)
        complete(record, from: session, at: endedAt)
        do {
            try contextSaver.save()
        } catch {
            context.rollback()
            if let calendarEventIdentifier {
                try? await calendar.deleteEvent(identifier: calendarEventIdentifier)
            }
            throw error
        }
        return CompletedMutation(
            session: record.session,
            calendarWarning: calendarWarning
        )
    }

    func update(
        session: StudyActivitySession,
        activity: StudyActivityKind,
        category: StudyActivityCategory,
        name: String?,
        startedAt: Date,
        duration: TimeInterval,
        userID: Int
    ) async throws -> CompletedMutation {
        guard session.isEditable else {
            throw StudyTimeSessionMutationError.readOnlySession
        }
        let record = try mutationRecord(for: session, userID: userID)
        guard let previousSession = record.session else {
            throw StudyTimeSessionMutationError.sessionUnavailable
        }
        if session.source == .calendar, record.calendarEventIdentifier == nil {
            throw StudyTimeSessionMutationError.calendarEventUnavailable
        }
        let boundedDuration = max(0, min(duration, 86_400))
        let endedAt = startedAt.addingTimeInterval(boundedDuration)
        let calendarWarning = try await updateCalendar(
            record, title: name ?? activity.title, start: startedAt, end: endedAt
        )
        record.category = category.rawValue
        record.activity = activity.rawValue
        record.name = name
        record.startedAt = startedAt
        record.endedAt = endedAt
        record.durationMs = Int(boundedDuration * 1_000)
        record.audioPlaybackMs = activity == .dailyAudio ? record.durationMs : nil
        record.syncPending = true
        do {
            try contextSaver.save()
        } catch {
            await restoreCalendar(record, previousSession: previousSession)
            throw StudyTimeMutationPersistenceError(underlying: error)
        }
        return CompletedMutation(
            session: record.session,
            calendarWarning: calendarWarning
        )
    }

    private func updateCalendar(
        _ record: LocalStudyActivitySession, title: String, start: Date, end: Date
    ) async throws -> String? {
        guard let identifier = record.calendarEventIdentifier else { return nil }
        do {
            try await calendar.updateEvent(identifier: identifier, title: title, start: start, end: end)
            return nil
        } catch StudyCalendarError.eventNotFound {
            record.calendarEventIdentifier = nil
            record.source = StudyActivitySource.manual.rawValue
            return StudyCalendarError.eventNotFound.localizedDescription
        } catch StudyCalendarError.accessDenied {
            record.calendarEventIdentifier = nil
            record.source = StudyActivitySource.manual.rawValue
            return StudyCalendarError.accessDenied.localizedDescription
        }
    }

    private func restoreCalendar(_ record: LocalStudyActivitySession, previousSession: StudyActivitySession) async {
        let identifier = record.calendarEventIdentifier
        context.rollback()
        guard let identifier else { return }
        try? await calendar.updateEvent(identifier: identifier,
                                        title: previousSession.name ?? previousSession.activity.title,
                                        start: previousSession.startedAt, end: previousSession.endedAt)
    }

    func delete(session: StudyActivitySession, userID: Int) throws {
        guard session.isEditable else {
            throw StudyTimeSessionMutationError.readOnlySession
        }
        let record = try mutationRecord(for: session, userID: userID)
        if session.source == .calendar, record.calendarEventIdentifier == nil {
            throw StudyTimeSessionMutationError.calendarEventUnavailable
        }
        record.isTombstone = true
        record.syncPending = true
        do {
            try contextSaver.save()
        } catch {
            context.rollback()
            throw StudyTimeMutationPersistenceError(underlying: error)
        }
    }

    func mergeRemoteSessions(
        _ remote: [StudyActivitySession],
        userID: Int,
        canContinue: @escaping @MainActor () -> Bool
    ) async throws -> LoadedSessions {
        try await StudyTimeHistoryImporter(context: context, saver: contextSaver)
            .mergeAndLoad(remote, userID: userID, canContinue: canContinue)
    }

    func deleteLocalData(userID: Int) throws {
        try context.delete(
            model: LocalStudyActivitySession.self,
            where: #Predicate { $0.userID == userID }
        )
        try context.save()
    }

    func loadLocalSessions(userID: Int) -> LoadedSessions? {
        let descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor) else {
            return nil
        }
        let sessions = records.compactMap(\.session)
        let active = records
            .first(where: { !$0.isTombstone && $0.endedAt == nil })?
            .activeSession
        return LoadedSessions(sessions: sessions, active: active)
    }

    func pendingEditableSessions(userID: Int) -> [StudyActivitySession] {
        let descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.syncPending && !$0.isTombstone
            }
        )
        return (try? context.fetch(descriptor))?
            .compactMap(\.session)
            .filter(\.isEditable) ?? []
    }

    func resolvedEditableSessions(
        _ remote: [StudyActivitySession],
        userID: Int
    ) throws -> [StudyActivitySession] {
        guard !remote.isEmpty else { return [] }
        let remoteIDs = remote.map(\.clientSessionId)
        let local = try context.fetch(
            FetchDescriptor<LocalStudyActivitySession>(
                predicate: #Predicate {
                    $0.userID == userID && remoteIDs.contains($0.clientSessionID)
                }
            )
        )
        let localByID = Dictionary(
            local.map { ($0.clientSessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return remote.compactMap { session in
            guard session.isEditable else { return nil }
            guard let local = localByID[session.clientSessionId] else {
                return session
            }
            if local.isTombstone {
                return nil
            }
            if local.syncPending {
                return local.session
            }
            return session
        }
    }

    func pushPending(
        userID: Int, mutationGeneration: Int, authorizationToken: String?,
        isCurrent: @escaping (Int, Int) -> Bool
    ) async -> PushResult {
        var failures: [String] = []
        let ownsRequest = { isCurrent(userID, mutationGeneration) }
        do {
            failures = try await pushDeletions(userID: userID, token: authorizationToken, isCurrent: ownsRequest)
            try await pushCompleted(userID: userID, token: authorizationToken, isCurrent: ownsRequest)
        } catch {
            guard ownsRequest() else { return PushResult(failures: failures, becameStale: true) }
            failures.append(error.localizedDescription)
        }
        return PushResult(failures: failures, becameStale: !ownsRequest())
    }

    private func pushDeletions(userID: Int, token: String?, isCurrent: () -> Bool) async throws -> [String] {
        let deletions = try context.fetch(FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate { $0.userID == userID && $0.syncPending && $0.isTombstone }
        ))
        var failures: [String] = []
        for record in deletions {
            try requireCurrent(isCurrent)
            if let warning = try await deleteCalendar(record, isCurrent: isCurrent) { failures.append(warning) }
            try requireCurrent(isCurrent)
            do {
                try await api.request("/api/study/activity-sessions/\(record.clientSessionID)",
                                      method: "DELETE", authorizationToken: token)
            } catch APIClientError.rejected(status: 404, message: _) {
                // The server already forgot this retry-safe tombstone.
            } catch {
                try requireCurrent(isCurrent)
                failures.append(error.localizedDescription)
                continue
            }
            try requireCurrent(isCurrent)
            record.syncPending = record.calendarEventIdentifier != nil
            // Commit before another network await: foreground failures can roll back the shared context.
            try context.save()
        }
        return failures
    }

    private func deleteCalendar(_ record: LocalStudyActivitySession, isCurrent: () -> Bool) async throws -> String? {
        guard let identifier = record.calendarEventIdentifier else { return nil }
        do {
            try await calendar.deleteEvent(identifier: identifier)
            try requireCurrent(isCurrent)
            record.calendarEventIdentifier = nil
            try context.save()
            return nil
        } catch {
            try requireCurrent(isCurrent)
            record.calendarEventIdentifier = identifier
            // A revoked calendar permission must not prevent deleting the study-log entry.
            return error.localizedDescription
        }
    }

    private func pushCompleted(userID: Int, token: String?, isCurrent: () -> Bool) async throws {
        try requireCurrent(isCurrent)
        let pending = try context.fetch(FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.syncPending && !$0.isTombstone && $0.endedAt != nil
            }
        ))
        guard !pending.isEmpty else { return }
        let saved = try await api.request(
            "/api/study/activity-sessions/batch", method: "POST",
            body: StudyActivityBatchRequest(sessions: pending.compactMap(\.session)),
            authorizationToken: token, response: [StudyActivitySession].self
        )
        try requireCurrent(isCurrent)
        let savedIDs = Set(saved.map(\.clientSessionId))
        pending.filter { savedIDs.contains($0.clientSessionID) }.forEach { $0.syncPending = false }
        try context.save()
    }

    private func requireCurrent(_ isCurrent: () -> Bool) throws {
        guard isCurrent() else { throw CancellationError() }
    }

    private func mutationRecord(
        for session: StudyActivitySession,
        userID: Int
    ) throws -> LocalStudyActivitySession {
        if let existing = record(
            clientSessionID: session.clientSessionId,
            userID: userID
        ) {
            return existing
        }
        if session.source == .calendar {
            throw StudyTimeSessionMutationError.calendarEventUnavailable
        }
        let inserted = LocalStudyActivitySession(session: session, userID: userID)
        context.insert(inserted)
        return inserted
    }

    private func record(
        clientSessionID: String,
        userID: Int
    ) -> LocalStudyActivitySession? {
        recordIncludingTombstones(
            clientSessionID: clientSessionID,
            userID: userID
        ).flatMap { $0.isTombstone ? nil : $0 }
    }

    private func recordIncludingTombstones(
        clientSessionID: String,
        userID: Int
    ) -> LocalStudyActivitySession? {
        var descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.clientSessionID == clientSessionID
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func complete(
        _ record: LocalStudyActivitySession,
        from active: StudyTimeActiveSession,
        at date: Date
    ) {
        let durationMs = min(
            86_400_000,
            max(0, Int(date.timeIntervalSince(active.startedAt) * 1_000))
        )
        record.endedAt = date
        record.durationMs = durationMs
        record.audioPlaybackMs = active.activity == .dailyAudio ? durationMs : nil
        record.cardsCreated = active.cardsCreated > 0 ? active.cardsCreated : nil
        record.syncPending = true
    }
}
