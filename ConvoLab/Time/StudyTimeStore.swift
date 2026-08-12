import Foundation
import SwiftData

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
    private let storageMode: StorageMode
    private let contextSaver: any StudyTimeContextSaving
    private let calendar: any StudyCalendarProviding
    private(set) var sessions: [StudyActivitySession] = []
    private(set) var analytics: StudyTimeAnalytics?
    private(set) var analyticsCache: [String: StudyTimeAnalytics] = [:]
    private(set) var analyticsCacheGeneration = 0
    private(set) var active: ActiveSession?
    private(set) var storageWriteErrorMessage: String?
    private(set) var syncErrorMessage: String?
    private var activeUserID: Int?
    private var synchronizationTask: Task<Void, Never>?
    private var synchronizingUserID: Int?
    private var pendingPushTask: Task<Void, Never>?
    private var pendingPushID: UUID?
    private var pendingPushNeedsAnotherPass = false
    private var localMutationGeneration = 0
    private var analyticsRequestGeneration = 0
    private var requestedAnalyticsAnchor: Date?

    init(
        api: APIClient,
        context: ModelContext,
        storageMode: StorageMode = .persistent,
        contextSaver: (any StudyTimeContextSaving)? = nil,
        calendar: (any StudyCalendarProviding)? = nil
    ) {
        self.api = api
        self.context = context
        self.storageMode = storageMode
        self.contextSaver = contextSaver ?? ModelContextStudyTimeSaver(context: context)
        self.calendar = calendar ?? LiveStudyCalendar()
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        localMutationGeneration += 1
        analyticsRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        analytics = nil
        analyticsCache = [:]
        analyticsCacheGeneration += 1
        activeUserID = userID
        loadLocalSessions(recoverAbandonedAutomatic: true)
    }

    func deactivate(at date: Date = .now) async {
        localMutationGeneration += 1
        analyticsRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        if let active {
            finish(active, at: date, enqueueSync: false)
        }
        await pushPending()
        activeUserID = nil
        sessions = []
        analytics = nil
        analyticsCache = [:]
        analyticsCacheGeneration += 1
        active = nil
        syncErrorMessage = nil
    }

    @discardableResult
    func start(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String? = nil,
        at date: Date = .now
    ) -> Bool {
        guard let userID = activeUserID else { return false }
        guard storageMode == .persistent else {
            storageWriteErrorMessage = StorageWriteUnavailableError(domain: .studyTime)
                .localizedDescription
            return false
        }
        if active?.activity == activity, active?.source == source, active?.name == name {
            return true
        }
        if active?.source == .manual, source == .automatic {
            return true
        }
        let previousActive = active
        if let previousActive {
            guard let previousRecord = record(
                clientSessionID: previousActive.clientSessionID
            ) else {
                loadLocalSessions()
                storageWriteErrorMessage = StudyTimeStoreError.sessionUnavailable
                    .localizedDescription
                return false
            }
            complete(previousRecord, from: previousActive, at: date)
        }
        let session = ActiveSession(
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
            localMutationGeneration += 1
            active = session
            storageWriteErrorMessage = nil
            if previousActive != nil {
                loadLocalSessions()
                Task {
                    await pushPending()
                    await refreshAnalytics()
                }
            }
            return true
        } catch {
            context.rollback()
            active = previousActive
            storageWriteErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func stop(
        activity expectedActivity: StudyActivityKind? = nil,
        source expectedSource: StudyActivitySource? = nil,
        at date: Date = .now
    ) -> Bool {
        guard let current = active,
              expectedActivity == nil || current.activity == expectedActivity,
              expectedSource == nil || current.source == expectedSource
        else {
            return true
        }
        return finish(current, at: date)
    }

    /// Most automatic timers only represent foreground app activity. Views also
    /// stop their own timers, but the app lifecycle is the reliable backstop
    /// when a child view misses the transition before suspension. Daily Audio
    /// is intentionally excluded because playback continues with the screen off.
    func stopForegroundAutomaticTracking(at date: Date = .now) {
        guard let current = active,
              current.source == .automatic,
              current.activity != .dailyAudio
        else {
            return
        }
        finish(current, at: date)
    }

    @discardableResult
    func addCreatedCards(_ count: Int = 1) -> Bool {
        guard var current = active, current.activity == .cardCreation else { return false }
        guard let record = record(clientSessionID: current.clientSessionID) else {
            loadLocalSessions()
            storageWriteErrorMessage = StudyTimeStoreError.sessionUnavailable.localizedDescription
            return false
        }
        let previousCount = current.cardsCreated
        current.cardsCreated += count
        record.cardsCreated = current.cardsCreated
        do {
            try contextSaver.save()
            localMutationGeneration += 1
            active = current
            storageWriteErrorMessage = nil
            return true
        } catch {
            context.rollback()
            current.cardsCreated = previousCount
            active = current
            storageWriteErrorMessage = error.localizedDescription
            return false
        }
    }

    func recordCompleted(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String?,
        startedAt: Date,
        duration: TimeInterval,
        addToCalendar: Bool = false
    ) async throws -> String? {
        try requirePersistentWrites()
        guard let userID = activeUserID else { return nil }
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
        context.insert(record)
        complete(record, from: session, at: endedAt)
        do {
            try contextSaver.save()
        } catch {
            context.rollback()
            if let calendarEventIdentifier {
                try? await calendar.deleteEvent(identifier: calendarEventIdentifier)
            }
            storageWriteErrorMessage = error.localizedDescription
            throw error
        }
        localMutationGeneration += 1
        storageWriteErrorMessage = nil
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
        try requirePersistentWrites()
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
                // Retain the calendar link when EventKit reports a transient
                // save failure so the user can retry the edit.
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
            loadLocalSessions()
            storageWriteErrorMessage = error.localizedDescription
            throw error
        }
        localMutationGeneration += 1
        storageWriteErrorMessage = nil
        loadLocalSessions()
        await pushPending()
        await refreshAnalytics()
        return calendarWarning
    }

    func delete(session: StudyActivitySession) async throws {
        try requirePersistentWrites()
        guard session.source != .automatic else {
            throw StudyTimeStoreError.automaticSession
        }
        guard let record = record(clientSessionID: session.clientSessionId) else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        if session.source == .calendar, record.calendarEventIdentifier == nil {
            throw StudyTimeStoreError.calendarEventUnavailable
        }
        record.isTombstone = true
        record.syncPending = true
        do {
            try contextSaver.save()
        } catch {
            context.rollback()
            loadLocalSessions()
            storageWriteErrorMessage = error.localizedDescription
            throw error
        }
        localMutationGeneration += 1
        storageWriteErrorMessage = nil
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
        analyticsRequestGeneration += 1
        let analyticsGeneration = analyticsRequestGeneration
        let analyticsAnchor = requestedAnalyticsAnchor ?? .now
        invalidateAnalyticsCache()
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
            let fetchedAnalytics = try await fetchAnalytics(anchorDate: analyticsAnchor)
            if activeUserID == userID,
               analyticsRequestGeneration == analyticsGeneration
            {
                analytics = fetchedAnalytics
                analyticsCache[analyticsAnchorString(from: analyticsAnchor)] = fetchedAnalytics
                analyticsCache[fetchedAnalytics.anchorDate] = fetchedAnalytics
            }
        } catch {
            if analyticsRequestGeneration == analyticsGeneration {
                failures.append(error.localizedDescription)
            }
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
            analyticsCache = [:]
            analyticsCacheGeneration += 1
            active = nil
        }
        try context.save()
    }

    @discardableResult
    private func finish(
        _ current: ActiveSession,
        at date: Date,
        enqueueSync: Bool = true
    ) -> Bool {
        guard let record = record(clientSessionID: current.clientSessionID) else {
            loadLocalSessions()
            storageWriteErrorMessage = StudyTimeStoreError.sessionUnavailable.localizedDescription
            return false
        }
        complete(record, from: current, at: date)
        do {
            try contextSaver.save()
        } catch {
            context.rollback()
            active = current
            storageWriteErrorMessage = error.localizedDescription
            return false
        }
        localMutationGeneration += 1
        active = nil
        storageWriteErrorMessage = nil
        loadLocalSessions()
        if enqueueSync {
            Task {
                await pushPending()
                await refreshAnalytics()
            }
        }
        return true
    }

    private func requirePersistentWrites() throws {
        guard storageMode == .persistent else {
            throw StorageWriteUnavailableError(domain: .studyTime)
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
            pendingPushNeedsAnotherPass = true
            await pendingPushTask.value
            return
        }
        guard activeUserID != nil else { return }
        let pushID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.drainPendingPushes()
            if self.pendingPushID == pushID {
                self.pendingPushTask = nil
                self.pendingPushID = nil
            }
        }
        pendingPushID = pushID
        pendingPushTask = task
        await task.value
    }

    private func drainPendingPushes() async {
        repeat {
            pendingPushNeedsAnotherPass = false
            guard let userID = activeUserID else { return }
            let mutationGeneration = localMutationGeneration
            await performPushPending(
                userID: userID,
                mutationGeneration: mutationGeneration
            )
            if activeUserID != nil,
               !isCurrentMutation(userID: userID, generation: mutationGeneration)
            {
                pendingPushNeedsAnotherPass = true
            }
        } while pendingPushNeedsAnotherPass
    }

    private func performPushPending(
        userID: Int,
        mutationGeneration: Int
    ) async {
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
                        guard isCurrentMutation(
                            userID: userID,
                            generation: mutationGeneration
                        ) else { return }
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
                guard isCurrentMutation(
                    userID: userID,
                    generation: mutationGeneration
                ) else { return }
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
                guard isCurrentMutation(
                    userID: userID,
                    generation: mutationGeneration
                ) else { return }
                let savedIDs = Set(saved.map(\.clientSessionId))
                pending.filter { savedIDs.contains($0.clientSessionID) }.forEach {
                    $0.syncPending = false
                }
                try context.save()
            }
        } catch {
            guard isCurrentMutation(
                userID: userID,
                generation: mutationGeneration
            ) else { return }
            failures.append(error.localizedDescription)
        }
        guard isCurrentMutation(
            userID: userID,
            generation: mutationGeneration
        ) else { return }
        syncErrorMessage = failures.first
        loadLocalSessions()
    }

    private func isCurrentMutation(userID: Int, generation: Int) -> Bool {
        activeUserID == userID && localMutationGeneration == generation
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

    @discardableResult
    func loadAnalytics(anchorDate: Date) async -> Bool {
        let loaded = await refreshAnalytics(anchorDate: anchorDate)
        if loaded {
            let confirmedAnchor = analytics
                .flatMap { analyticsAnchorDate(from: $0.anchorDate) }
                ?? anchorDate
            requestedAnalyticsAnchor = Calendar.current.isDateInToday(confirmedAnchor)
                ? nil
                : confirmedAnchor
        }
        return loaded
    }

    func cachedAnalytics(anchorDate: Date) -> StudyTimeAnalytics? {
        analyticsCache[analyticsAnchorString(from: anchorDate)]
    }

    @discardableResult
    func prefetchAnalytics(
        anchorDate: Date,
        reportFailure: Bool = false
    ) async -> Bool {
        let key = analyticsAnchorString(from: anchorDate)
        if analyticsCache[key] != nil {
            return true
        }
        guard let userID = activeUserID else { return false }
        let cacheGeneration = analyticsCacheGeneration
        do {
            let fetchedAnalytics = try await fetchAnalytics(anchorDate: anchorDate)
            guard activeUserID == userID,
                  analyticsCacheGeneration == cacheGeneration
            else {
                return false
            }
            analyticsCache[key] = fetchedAnalytics
            analyticsCache[fetchedAnalytics.anchorDate] = fetchedAnalytics
            return true
        } catch {
            if reportFailure,
               activeUserID == userID,
               analyticsCacheGeneration == cacheGeneration
            {
                syncErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    @discardableResult
    func selectCachedAnalytics(anchorDate: Date) -> Bool {
        let key = analyticsAnchorString(from: anchorDate)
        guard let cached = analyticsCache[key] else { return false }
        analyticsRequestGeneration += 1
        analytics = cached
        let confirmedAnchor = analyticsAnchorDate(from: cached.anchorDate) ?? anchorDate
        requestedAnalyticsAnchor = Calendar.current.isDateInToday(confirmedAnchor)
            ? nil
            : confirmedAnchor
        return true
    }

    @discardableResult
    private func refreshAnalytics(anchorDate: Date? = nil) async -> Bool {
        guard let userID = activeUserID else { return false }
        let effectiveAnchor = anchorDate ?? requestedAnalyticsAnchor ?? .now
        invalidateAnalyticsCache()
        analyticsRequestGeneration += 1
        let requestGeneration = analyticsRequestGeneration
        do {
            let fetchedAnalytics = try await fetchAnalytics(anchorDate: effectiveAnchor)
            if activeUserID == userID,
               analyticsRequestGeneration == requestGeneration
            {
                analytics = fetchedAnalytics
                analyticsCache[analyticsAnchorString(from: effectiveAnchor)] = fetchedAnalytics
                analyticsCache[fetchedAnalytics.anchorDate] = fetchedAnalytics
                return true
            }
        } catch {
            if activeUserID == userID,
               analyticsRequestGeneration == requestGeneration,
               syncErrorMessage == nil
            {
                syncErrorMessage = error.localizedDescription
            }
        }
        return false
    }

    private func fetchAnalytics(anchorDate: Date = .now) async throws -> StudyTimeAnalytics {
        let anchorDateString = analyticsAnchorString(from: anchorDate)

        return try await api.request(
            "/api/study/activity-analytics",
            query: [
                URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
                URLQueryItem(
                    name: "weekStartsOn",
                    value: String(Calendar.current.firstWeekday)
                ),
                URLQueryItem(name: "anchorDate", value: anchorDateString),
            ],
            response: StudyTimeAnalytics.self
        )
    }

    private func analyticsAnchorString(from anchorDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: anchorDate)
    }

    private func analyticsAnchorDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func invalidateAnalyticsCache() {
        analyticsCache = [:]
        analyticsCacheGeneration += 1
    }
}
