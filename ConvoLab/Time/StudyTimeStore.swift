import Foundation
import SwiftData

private enum StudyTimeStoreError: LocalizedError {
    case automaticSession
    case calendarEventUnavailable
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .automaticSession:
            "Automatically recorded study time cannot be changed."
        case .calendarEventUnavailable:
            "The linked calendar event is not available on this device."
        case .sessionUnavailable:
            "This study entry is no longer available. Refresh and try again."
        }
    }
}

@Observable
final class StudyTimeStore {
    private static let automaticRecoveryLimit: TimeInterval = 5 * 60

    struct ActiveSession: Equatable {
        let clientSessionID: String
        let category: StudyActivityCategory
        let activity: StudyActivityKind
        let source: StudyActivitySource
        let name: String?
        let startedAt: Date
        var cardsCreated: Int
    }

    private let api: APIClient
    private let context: ModelContext
    private(set) var sessions: [StudyActivitySession] = []
    private(set) var analytics: StudyTimeAnalytics?
    private(set) var active: ActiveSession?
    private(set) var syncErrorMessage: String?
    private var activeUserID: Int?
    private var synchronizationTask: Task<Void, Never>?
    private var synchronizingUserID: Int?
    private var pendingPushTask: Task<Void, Never>?
    private var localMutationGeneration = 0

    init(api: APIClient, context: ModelContext) {
        self.api = api
        self.context = context
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        localMutationGeneration += 1
        activeUserID = userID
        loadLocalSessions(recoverAbandonedAutomatic: true)
    }

    func deactivate(at date: Date = .now) async {
        localMutationGeneration += 1
        if let active {
            finish(active, at: date, enqueueSync: false)
        }
        await pushPending()
        activeUserID = nil
        sessions = []
        analytics = nil
        active = nil
        syncErrorMessage = nil
    }

    func start(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String? = nil,
        at date: Date = .now
    ) {
        guard let userID = activeUserID else { return }
        if active?.activity == activity, active?.source == source, active?.name == name {
            return
        }
        if active?.source == .manual, source == .automatic {
            return
        }
        stop(at: date)
        let session = ActiveSession(
            clientSessionID: UUID().uuidString.lowercased(),
            category: activity.category,
            activity: activity,
            source: source,
            name: name,
            startedAt: date,
            cardsCreated: 0
        )
        active = session
        localMutationGeneration += 1
        context.insert(LocalStudyActivitySession(active: session, userID: userID))
        try? context.save()
    }

    func stop(
        activity expectedActivity: StudyActivityKind? = nil,
        source expectedSource: StudyActivitySource? = nil,
        at date: Date = .now
    ) {
        guard let current = active,
              expectedActivity == nil || current.activity == expectedActivity,
              expectedSource == nil || current.source == expectedSource
        else {
            return
        }
        finish(current, at: date)
    }

    func addCreatedCards(_ count: Int = 1) {
        guard var current = active, current.activity == .cardCreation else { return }
        current.cardsCreated += count
        active = current
        guard let record = record(clientSessionID: current.clientSessionID) else { return }
        localMutationGeneration += 1
        record.cardsCreated = current.cardsCreated
        try? context.save()
    }

    func recordCompleted(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String?,
        startedAt: Date,
        duration: TimeInterval,
        addToCalendar: Bool = false
    ) async throws -> String? {
        guard let userID = activeUserID else { return nil }
        let boundedDuration = max(0, min(duration, 86_400))
        let endedAt = startedAt.addingTimeInterval(boundedDuration)
        var effectiveSource = source
        var calendarEventIdentifier: String?
        var calendarWarning: String?
        if addToCalendar {
            do {
                calendarEventIdentifier = try await StudyCalendarService.addEvent(
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
        let session = ActiveSession(
            clientSessionID: UUID().uuidString.lowercased(),
            category: activity.category,
            activity: activity,
            source: effectiveSource,
            name: name,
            startedAt: startedAt,
            cardsCreated: 0
        )
        let record = LocalStudyActivitySession(active: session, userID: userID)
        record.calendarEventIdentifier = calendarEventIdentifier
        localMutationGeneration += 1
        context.insert(record)
        complete(record, from: session, at: endedAt)
        do {
            try context.save()
        } catch {
            if let calendarEventIdentifier {
                try? await StudyCalendarService.deleteEvent(identifier: calendarEventIdentifier)
            }
            throw error
        }
        loadLocalSessions()
        await pushPending()
        await refreshAnalytics()
        return calendarWarning
    }

    func update(
        session: StudyActivitySession,
        activity: StudyActivityKind,
        name: String?,
        startedAt: Date,
        duration: TimeInterval
    ) async throws -> String? {
        guard session.source != .automatic else {
            throw StudyTimeStoreError.automaticSession
        }
        guard let record = record(clientSessionID: session.clientSessionId) else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        guard let previousSession = record.session else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        if session.source == .calendar, record.calendarEventIdentifier == nil {
            throw StudyTimeStoreError.calendarEventUnavailable
        }
        let wasSyncPending = record.syncPending
        let wasTombstone = record.isTombstone
        let previousCalendarEventIdentifier = record.calendarEventIdentifier
        let boundedDuration = max(0, min(duration, 86_400))
        let endedAt = startedAt.addingTimeInterval(boundedDuration)
        var calendarWarning: String?
        if let identifier = record.calendarEventIdentifier {
            do {
                try await StudyCalendarService.updateEvent(
                    identifier: identifier,
                    title: name ?? activity.title,
                    start: startedAt,
                    end: endedAt
                )
            } catch {
                calendarWarning = error.localizedDescription
                record.calendarEventIdentifier = nil
                record.source = StudyActivitySource.manual.rawValue
            }
        }
        localMutationGeneration += 1
        record.category = activity.category.rawValue
        record.activity = activity.rawValue
        record.name = name
        record.startedAt = startedAt
        record.endedAt = endedAt
        record.durationMs = Int(boundedDuration * 1_000)
        record.audioPlaybackMs = activity == .dailyAudio ? record.durationMs : nil
        record.syncPending = true
        do {
            try context.save()
        } catch {
            if let identifier = record.calendarEventIdentifier {
                try? await StudyCalendarService.updateEvent(
                    identifier: identifier,
                    title: previousSession.name ?? previousSession.activity.title,
                    start: previousSession.startedAt,
                    end: previousSession.endedAt
                )
            }
            record.apply(previousSession)
            record.syncPending = wasSyncPending
            record.isTombstone = wasTombstone
            record.calendarEventIdentifier = previousCalendarEventIdentifier
            try? context.save()
            loadLocalSessions()
            throw error
        }
        loadLocalSessions()
        await pushPending()
        await refreshAnalytics()
        return calendarWarning
    }

    func delete(session: StudyActivitySession) async throws {
        guard session.source != .automatic else {
            throw StudyTimeStoreError.automaticSession
        }
        guard let record = record(clientSessionID: session.clientSessionId) else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        if session.source == .calendar, record.calendarEventIdentifier == nil {
            throw StudyTimeStoreError.calendarEventUnavailable
        }
        let wasSyncPending = record.syncPending
        let wasTombstone = record.isTombstone
        localMutationGeneration += 1
        record.isTombstone = true
        record.syncPending = true
        do {
            try context.save()
        } catch {
            record.isTombstone = wasTombstone
            record.syncPending = wasSyncPending
            loadLocalSessions()
            throw error
        }
        loadLocalSessions()
        await pushPending()
        await refreshAnalytics()
    }

    func synchronize() async {
        guard let requestedUserID = activeUserID else { return }
        if let synchronizationTask {
            let inFlightUserID = synchronizingUserID
            await synchronizationTask.value
            guard activeUserID == requestedUserID else { return }
            if inFlightUserID == requestedUserID {
                return
            }
        }
        guard activeUserID == requestedUserID else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSynchronization(userID: requestedUserID)
        }
        synchronizationTask = task
        synchronizingUserID = requestedUserID
        await task.value
        if synchronizingUserID == requestedUserID {
            synchronizationTask = nil
            synchronizingUserID = nil
        }
    }

    private func performSynchronization(userID: Int) async {
        await pushPending()
        let pushFailure = syncErrorMessage
        let to = Date.now.addingTimeInterval(60)
        let from = to.addingTimeInterval(-93 * 86_400)
        let requestMutationGeneration = localMutationGeneration
        var failures = pushFailure.map { [$0] } ?? []
        do {
            let remote = try await api.request(
                "/api/study/activity-sessions",
                query: [
                    URLQueryItem(name: "from", value: from.ISO8601Format()),
                    URLQueryItem(name: "to", value: to.ISO8601Format()),
                ],
                response: [StudyActivitySession].self
            )
            if requestMutationGeneration == localMutationGeneration {
                let existing = try context.fetch(
                    FetchDescriptor<LocalStudyActivitySession>(
                        predicate: #Predicate { $0.userID == userID }
                    )
                )
                var recordsByID = existing.reduce(into: [String: LocalStudyActivitySession]()) {
                    records, record in
                    if records[record.clientSessionID] == nil {
                        records[record.clientSessionID] = record
                    }
                }
                for session in remote {
                    if let record = recordsByID[session.clientSessionId] {
                        if !record.isTombstone, !record.syncPending {
                            record.apply(session)
                        }
                    } else {
                        let record = LocalStudyActivitySession(session: session, userID: userID)
                        context.insert(record)
                        recordsByID[session.clientSessionId] = record
                    }
                }
                try context.save()
                loadLocalSessions()
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            let fetchedAnalytics = try await fetchAnalytics()
            if activeUserID == userID {
                analytics = fetchedAnalytics
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        if activeUserID == userID {
            syncErrorMessage = failures.first
        }
    }

    func deleteLocalData(userID: Int) throws {
        localMutationGeneration += 1
        try context.delete(
            model: LocalStudyActivitySession.self,
            where: #Predicate { $0.userID == userID }
        )
        if activeUserID == userID {
            sessions = []
            analytics = nil
            active = nil
        }
        try context.save()
    }

    private func finish(
        _ current: ActiveSession,
        at date: Date,
        enqueueSync: Bool = true
    ) {
        guard let record = record(clientSessionID: current.clientSessionID) else {
            active = nil
            return
        }
        localMutationGeneration += 1
        complete(record, from: current, at: date)
        active = nil
        try? context.save()
        loadLocalSessions()
        if enqueueSync {
            Task {
                await pushPending()
                await refreshAnalytics()
            }
        }
    }

    private func complete(
        _ record: LocalStudyActivitySession,
        from active: ActiveSession,
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

    private func pushPending() async {
        if let pendingPushTask {
            await pendingPushTask.value
            return
        }
        guard let userID = activeUserID else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPushPending(userID: userID)
        }
        pendingPushTask = task
        await task.value
        pendingPushTask = nil
    }

    private func performPushPending(userID: Int) async {
        var failures: [String] = []
        do {
            let deletions = try context.fetch(
                FetchDescriptor<LocalStudyActivitySession>(
                    predicate: #Predicate {
                        $0.userID == userID && $0.syncPending && $0.isTombstone
                    }
                )
            )
            var deletedAny = false
            for record in deletions {
                if let identifier = record.calendarEventIdentifier {
                    do {
                        try await StudyCalendarService.deleteEvent(identifier: identifier)
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
                    let _: IgnoredResponse = try await api.request(
                        "/api/study/activity-sessions/\(record.clientSessionID)",
                        method: "DELETE"
                    )
                } catch APIClientError.rejected(status: 404, message: _) {
                    // The server already forgot this retry-safe tombstone.
                } catch {
                    failures.append(error.localizedDescription)
                    continue
                }
                record.syncPending = record.calendarEventIdentifier != nil
                deletedAny = true
            }
            if deletedAny {
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
                let savedIDs = Set(saved.map(\.clientSessionId))
                pending.filter { savedIDs.contains($0.clientSessionID) }.forEach {
                    $0.syncPending = false
                }
                try context.save()
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        syncErrorMessage = failures.first
        loadLocalSessions()
    }

    private func loadLocalSessions(recoverAbandonedAutomatic: Bool = false) {
        guard let userID = activeUserID else { return }
        let descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate { $0.userID == userID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        guard let records = try? context.fetch(descriptor) else { return }
        sessions = records.compactMap(\.session)
        if let running = records.first(where: { !$0.isTombstone && $0.endedAt == nil }) {
            active = running.activeSession
            if recoverAbandonedAutomatic,
               let active,
               active.source == .automatic,
               Date.now.timeIntervalSince(active.startedAt) > Self.automaticRecoveryLimit
            {
                finish(
                    active,
                    at: active.startedAt.addingTimeInterval(Self.automaticRecoveryLimit)
                )
            }
        } else {
            active = nil
        }
    }

    private func record(clientSessionID: String) -> LocalStudyActivitySession? {
        guard let userID = activeUserID else { return nil }
        var descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.clientSessionID == clientSessionID
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first(where: { !$0.isTombstone })
    }

    private func refreshAnalytics() async {
        do {
            analytics = try await fetchAnalytics()
        } catch {
            if syncErrorMessage == nil {
                syncErrorMessage = error.localizedDescription
            }
        }
    }

    private func fetchAnalytics() async throws -> StudyTimeAnalytics {
        try await api.request(
            "/api/study/activity-analytics",
            query: [
                URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
                URLQueryItem(
                    name: "weekStartsOn",
                    value: String(Calendar.current.firstWeekday)
                ),
            ],
            response: StudyTimeAnalytics.self
        )
    }
}
