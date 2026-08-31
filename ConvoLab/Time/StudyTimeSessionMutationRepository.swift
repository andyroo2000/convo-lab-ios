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

    var errorDescription: String? {
        switch self {
        case .readOnlySession:
            "Automatically or externally recorded study time cannot be changed."
        case .calendarEventUnavailable:
            "The linked calendar event is not available on this device."
        case .sessionUnavailable:
            "This study entry is no longer available. Refresh and try again."
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

    func start(
        replacing current: StudyTimeActiveSession?,
        activity: StudyActivityKind,
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
            category: activity.category,
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
        source: StudyActivitySource,
        name: String?,
        startedAt: Date,
        duration: TimeInterval,
        addToCalendar: Bool,
        clientSessionID: String?,
        userID: Int
    ) async throws -> CompletedMutation {
        if let clientSessionID,
           let existing = record(clientSessionID: clientSessionID, userID: userID)
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
            category: activity.category,
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
        var calendarWarning: String?
        if let identifier = record.calendarEventIdentifier {
            do {
                try await calendar.updateEvent(
                    identifier: identifier,
                    title: name ?? activity.title,
                    start: startedAt,
                    end: endedAt
                )
            } catch StudyCalendarError.eventNotFound {
                calendarWarning = StudyCalendarError.eventNotFound.localizedDescription
                record.calendarEventIdentifier = nil
                record.source = StudyActivitySource.manual.rawValue
            } catch StudyCalendarError.accessDenied {
                calendarWarning = StudyCalendarError.accessDenied.localizedDescription
                record.calendarEventIdentifier = nil
                record.source = StudyActivitySource.manual.rawValue
            } catch {
                throw error
            }
        }
        record.category = activity.category.rawValue
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
            let calendarEventIdentifier = record.calendarEventIdentifier
            context.rollback()
            if let identifier = calendarEventIdentifier {
                try? await calendar.updateEvent(
                    identifier: identifier,
                    title: previousSession.name ?? previousSession.activity.title,
                    start: previousSession.startedAt,
                    end: previousSession.endedAt
                )
            }
            throw StudyTimeMutationPersistenceError(underlying: error)
        }
        return CompletedMutation(
            session: record.session,
            calendarWarning: calendarWarning
        )
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
        userID: Int
    ) throws -> [StudyActivitySession] {
        guard !remote.isEmpty else { return [] }
        let remoteIDs = remote.map(\.clientSessionId)
        let existing = try context.fetch(
            FetchDescriptor<LocalStudyActivitySession>(
                predicate: #Predicate {
                    $0.userID == userID && remoteIDs.contains($0.clientSessionID)
                }
            )
        )
        var recordsByID = existing.reduce(into: [String: LocalStudyActivitySession]()) {
            records, record in
            if records[record.clientSessionID] == nil {
                records[record.clientSessionID] = record
            }
        }
        var didMutate = false
        for session in remote {
            if let record = recordsByID[session.clientSessionId] {
                if !record.isTombstone,
                   !record.syncPending,
                   record.session != session
                {
                    record.apply(session)
                    didMutate = true
                }
            } else {
                let record = LocalStudyActivitySession(session: session, userID: userID)
                context.insert(record)
                recordsByID[session.clientSessionId] = record
                didMutate = true
            }
        }
        if didMutate {
            try context.save()
        }
        return remote.compactMap { recordsByID[$0.clientSessionId]?.session }
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
        userID: Int,
        mutationGeneration: Int,
        isCurrent: (Int, Int) -> Bool
    ) async -> PushResult {
        var failures: [String] = []
        do {
            let deletions = try context.fetch(
                FetchDescriptor<LocalStudyActivitySession>(
                    predicate: #Predicate {
                        $0.userID == userID && $0.syncPending && $0.isTombstone
                    }
                )
            )
            for record in deletions {
                if let identifier = record.calendarEventIdentifier {
                    do {
                        try await calendar.deleteEvent(identifier: identifier)
                        guard isCurrent(userID, mutationGeneration) else {
                            return PushResult(failures: failures, becameStale: true)
                        }
                        record.calendarEventIdentifier = nil
                        try context.save()
                    } catch {
                        record.calendarEventIdentifier = identifier
                        failures.append(error.localizedDescription)
                        // Calendar access may have been revoked. The explicit
                        // study-log deletion must still be allowed to finish,
                        // while retaining the identifier for a later retry.
                    }
                }
                do {
                    try await api.request(
                        "/api/study/activity-sessions/\(record.clientSessionID)",
                        method: "DELETE"
                    )
                } catch APIClientError.rejected(status: 404, message: _) {
                    // The server already forgot this retry-safe tombstone.
                } catch {
                    failures.append(error.localizedDescription)
                    continue
                }
                guard isCurrent(userID, mutationGeneration) else {
                    return PushResult(failures: failures, becameStale: true)
                }
                record.syncPending = record.calendarEventIdentifier != nil
                // Do not carry dirty ModelContext state across the next network
                // await. Foreground write failures use context.rollback(), so
                // each background mutation must be committed first.
                try context.save()
            }
            let pending = try context.fetch(
                FetchDescriptor<LocalStudyActivitySession>(
                    predicate: #Predicate {
                        $0.userID == userID
                            && $0.syncPending
                            && !$0.isTombstone
                            && $0.endedAt != nil
                    }
                )
            )
            if !pending.isEmpty {
                let payload = pending.compactMap(\.session)
                let saved = try await api.request(
                    "/api/study/activity-sessions/batch",
                    method: "POST",
                    body: StudyActivityBatchRequest(sessions: payload),
                    response: [StudyActivitySession].self
                )
                guard isCurrent(userID, mutationGeneration) else {
                    return PushResult(failures: failures, becameStale: true)
                }
                let savedIDs = Set(saved.map(\.clientSessionId))
                pending.filter { savedIDs.contains($0.clientSessionID) }.forEach {
                    $0.syncPending = false
                }
                try context.save()
            }
        } catch {
            guard isCurrent(userID, mutationGeneration) else {
                return PushResult(failures: failures, becameStale: true)
            }
            failures.append(error.localizedDescription)
        }
        return PushResult(failures: failures, becameStale: false)
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
        var descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.clientSessionID == clientSessionID
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first(where: { !$0.isTombstone })
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
