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

@Observable
final class StudyTimeStore {
    private static let automaticRecoveryLimit: TimeInterval = 5 * 60

    private enum StorageWriteOperation: Equatable {
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
    private let googleCalendar: any GoogleCalendarConnectionServing
    private let googleCalendarAuthorizer: any GoogleCalendarAuthorizing
    private let weeklyRecapService: any WeeklyStudyRecapServing
    private let snapshotCache: any StudyTimeSnapshotCaching
    private let now: () -> Date
    private(set) var sessions: [StudyActivitySession] = []
    private(set) var editableSessions: [StudyActivitySession] = []
    private(set) var editableSessionsNextCursor: String?
    private(set) var editableSessionsIsLoading = false
    private(set) var editableSessionsErrorMessage: String?
    private(set) var analytics: StudyTimeAnalytics?
    private(set) var analyticsCache: [String: StudyTimeAnalytics] = [:]
    private(set) var analyticsCacheGeneration = 0
    private(set) var active: ActiveSession?
    private(set) var storageWriteErrorMessage: String?
    private var storageWriteErrorOperation: StorageWriteOperation?
    private(set) var syncErrorMessage: String?
    private(set) var googleCalendarStatus: GoogleCalendarConnectionStatus?
    private(set) var googleCalendarIsLoading = false
    private(set) var googleCalendarIsWorking = false
    private(set) var googleCalendarErrorMessage: String?
    private(set) var weeklyRecap: WeeklyStudyRecap?
    private(set) var weeklyRecapIsLoading = false
    private(set) var weeklyRecapErrorMessage: String?
    private var activeUserID: Int?
    private var synchronizationTask: Task<Void, Never>?
    private var synchronizingUserID: Int?
    private var pendingPushTask: Task<Void, Never>?
    private var pendingPushID: UUID?
    private var pendingPushNeedsAnotherPass = false
    private var localMutationGeneration = 0
    private var analyticsRequestGeneration = 0
    private var googleCalendarRequestGeneration = 0
    private var weeklyRecapRequestGeneration = 0
    private var weeklyRecapRefreshedAt: Date?
    private var requestedAnalyticsAnchor: Date?

    init(
        api: APIClient,
        context: ModelContext,
        storageMode: StorageMode = .persistent,
        contextSaver: (any StudyTimeContextSaving)? = nil,
        calendar: (any StudyCalendarProviding)? = nil,
        googleCalendar: (any GoogleCalendarConnectionServing)? = nil,
        googleCalendarAuthorizer: (any GoogleCalendarAuthorizing)? = nil,
        weeklyRecapService: (any WeeklyStudyRecapServing)? = nil,
        snapshotCache: (any StudyTimeSnapshotCaching)? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.api = api
        self.context = context
        self.storageMode = storageMode
        self.contextSaver = contextSaver ?? ModelContextStudyTimeSaver(context: context)
        self.calendar = calendar ?? LiveStudyCalendar()
        self.googleCalendar = googleCalendar ?? LiveGoogleCalendarConnectionService(api: api)
        self.googleCalendarAuthorizer = googleCalendarAuthorizer
            ?? LiveGoogleCalendarAuthorizer()
        self.weeklyRecapService = weeklyRecapService ?? LiveWeeklyStudyRecapService(api: api)
        self.snapshotCache = snapshotCache ?? UserDefaultsStudyTimeSnapshotCache()
        self.now = now
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        localMutationGeneration += 1
        analyticsRequestGeneration += 1
        googleCalendarRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        analytics = nil
        analyticsCache = [:]
        analyticsCacheGeneration += 1
        clearStorageWriteError()
        googleCalendarStatus = nil
        googleCalendarErrorMessage = nil
        googleCalendarIsLoading = false
        googleCalendarIsWorking = false
        weeklyRecap = nil
        weeklyRecapErrorMessage = nil
        weeklyRecapIsLoading = false
        weeklyRecapRefreshedAt = nil
        activeUserID = userID
        loadLocalSessions(recoverAbandonedAutomatic: true)
        editableSessions = Array(
            sessions.filter(\.isEditable).sorted { $0.startedAt > $1.startedAt }.prefix(20)
        )
        editableSessionsNextCursor = nil
        editableSessionsErrorMessage = nil
        editableSessionsIsLoading = false
        restoreSnapshot(userID: userID)
    }

    @discardableResult
    func deactivate(at date: Date = .now) async -> Bool {
        localMutationGeneration += 1
        analyticsRequestGeneration += 1
        googleCalendarRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        let didFinish = active.map {
            finish($0, at: date, enqueueSync: false)
        } ?? true
        await pushPending()
        activeUserID = nil
        sessions = []
        editableSessions = []
        editableSessionsNextCursor = nil
        editableSessionsErrorMessage = nil
        editableSessionsIsLoading = false
        analytics = nil
        analyticsCache = [:]
        analyticsCacheGeneration += 1
        active = nil
        clearStorageWriteError()
        syncErrorMessage = nil
        googleCalendarStatus = nil
        googleCalendarErrorMessage = nil
        googleCalendarIsLoading = false
        googleCalendarIsWorking = false
        weeklyRecap = nil
        weeklyRecapErrorMessage = nil
        weeklyRecapIsLoading = false
        weeklyRecapRefreshedAt = nil
        // A failed finish leaves its open row durable. A later activate() will
        // reload that same session so callers can retry without duplication.
        return didFinish
    }

    func loadGoogleCalendarConnection() async {
        guard let requestedUserID = activeUserID, !googleCalendarIsWorking else { return }
        googleCalendarRequestGeneration += 1
        let requestGeneration = googleCalendarRequestGeneration
        googleCalendarIsLoading = true
        googleCalendarErrorMessage = nil
        defer {
            if activeUserID == requestedUserID,
               googleCalendarRequestGeneration == requestGeneration
            {
                googleCalendarIsLoading = false
            }
        }
        do {
            let status = try await googleCalendar.status()
            guard activeUserID == requestedUserID,
                  googleCalendarRequestGeneration == requestGeneration
            else { return }
            googleCalendarStatus = status
        } catch {
            guard activeUserID == requestedUserID,
                  googleCalendarRequestGeneration == requestGeneration
            else { return }
            googleCalendarErrorMessage = googleCalendarFriendlyMessage(for: error)
        }
    }

    func makeGoogleCalendarSettingsModel() -> GoogleCalendarSettingsModel? {
        guard googleCalendarStatus?.connected == true,
              let requestedUserID = activeUserID
        else { return nil }
        return GoogleCalendarSettingsModel(
            service: googleCalendar,
            initialSettings: googleCalendarStatus?.settings
        ) { [weak self] in
            await self?.loadGoogleCalendarConnection()
        } didSync: { [weak self] in
            guard let self, self.activeUserID == requestedUserID else { return }
            async let status: Void = self.loadGoogleCalendarConnection()
            async let studyTime: Void = self.synchronize()
            _ = await (status, studyTime)
        }
    }

    func loadWeeklyRecap(
        timeZone: String = TimeZone.autoupdatingCurrent.identifier,
        force: Bool = false
    ) async {
        guard let requestedUserID = activeUserID, !weeklyRecapIsLoading else { return }
        if !force, let weeklyRecapRefreshedAt {
            let age = now().timeIntervalSince(weeklyRecapRefreshedAt)
            if age >= 0, age < 15 * 60 {
                return
            }
        }
        weeklyRecapRequestGeneration += 1
        let generation = weeklyRecapRequestGeneration
        weeklyRecapIsLoading = true
        weeklyRecapErrorMessage = nil
        defer {
            if activeUserID == requestedUserID, weeklyRecapRequestGeneration == generation {
                weeklyRecapIsLoading = false
            }
        }
        do {
            let value = try await weeklyRecapService.recap(timeZone: timeZone, weekStartsOn: 2)
            guard activeUserID == requestedUserID, weeklyRecapRequestGeneration == generation else { return }
            weeklyRecap = value
            weeklyRecapRefreshedAt = now()
            persistSnapshot(timeZone: timeZone)
        } catch {
            guard activeUserID == requestedUserID, weeklyRecapRequestGeneration == generation else { return }
            weeklyRecapErrorMessage = "Couldn’t load your weekly recap. Pull to refresh and try again."
        }
    }

    func loadEditableSessions(reset: Bool = true) async {
        guard let requestedUserID = activeUserID, !editableSessionsIsLoading else { return }
        let cursor = reset ? nil : editableSessionsNextCursor
        if !reset, cursor == nil { return }
        editableSessionsIsLoading = true
        editableSessionsErrorMessage = nil
        defer {
            if activeUserID == requestedUserID {
                editableSessionsIsLoading = false
            }
        }

        do {
            var query = [URLQueryItem(name: "per_page", value: "20")]
            if let cursor {
                query.append(URLQueryItem(name: "cursor", value: cursor))
            }
            let page: EditableStudyActivitySessionPage = try await api.request(
                "/api/study/activity-sessions/editable",
                query: query
            )
            guard activeUserID == requestedUserID else { return }
            let resolvedItems = try mergeRemoteSessions(page.items, userID: requestedUserID)
                .filter(\.isEditable)
            mergeCompletedSessionsIntoLocalView(resolvedItems)
            if reset {
                editableSessions = sortedUniqueEditableSessions(
                    resolvedItems + pendingEditableSessions(userID: requestedUserID)
                )
            } else {
                let existingIDs = Set(editableSessions.map(\.clientSessionId))
                editableSessions.append(contentsOf: resolvedItems.filter {
                    !existingIDs.contains($0.clientSessionId)
                })
                editableSessions = sortedUniqueEditableSessions(editableSessions)
            }
            editableSessionsNextCursor = page.nextCursor
        } catch {
            guard activeUserID == requestedUserID else { return }
            editableSessionsErrorMessage = "Couldn’t load editable entries. Try again."
        }
    }

    func connectGoogleCalendar() async {
        guard let requestedUserID = activeUserID,
              !googleCalendarIsLoading, !googleCalendarIsWorking
        else { return }
        googleCalendarRequestGeneration += 1
        let requestGeneration = googleCalendarRequestGeneration
        googleCalendarIsWorking = true
        googleCalendarErrorMessage = nil
        defer {
            if activeUserID == requestedUserID,
               googleCalendarRequestGeneration == requestGeneration
            {
                googleCalendarIsWorking = false
            }
        }
        do {
            let authorizationURL = try await googleCalendar.authorizationURL()
            let callbackURL = try await googleCalendarAuthorizer.authorize(at: authorizationURL)
            let callback = try GoogleCalendarCallback.parse(callbackURL)
            guard callback.connected else { throw GoogleCalendarConnectionError.connectionFailed(reason: callback.reason) }
            guard activeUserID == requestedUserID, googleCalendarRequestGeneration == requestGeneration else { return }
            googleCalendarStatus = .init(
                connected: true,
                accountEmail: nil,
                scopes: [],
                settings: nil,
                connectedAt: nil,
                lastSyncedAt: nil
            )
            let status = try await googleCalendar.status()
            guard activeUserID == requestedUserID,
                  googleCalendarRequestGeneration == requestGeneration
            else { return }
            googleCalendarStatus = status
        } catch {
            guard activeUserID == requestedUserID,
                  googleCalendarRequestGeneration == requestGeneration
            else { return }
            googleCalendarErrorMessage = googleCalendarFriendlyMessage(for: error)
        }
    }

    func disconnectGoogleCalendar() async {
        guard let requestedUserID = activeUserID,
              !googleCalendarIsLoading, !googleCalendarIsWorking
        else { return }
        googleCalendarRequestGeneration += 1
        let requestGeneration = googleCalendarRequestGeneration
        googleCalendarIsWorking = true
        googleCalendarErrorMessage = nil
        defer {
            if activeUserID == requestedUserID,
               googleCalendarRequestGeneration == requestGeneration
            {
                googleCalendarIsWorking = false
            }
        }
        do {
            try await googleCalendar.disconnect()
            guard activeUserID == requestedUserID,
                  googleCalendarRequestGeneration == requestGeneration
            else { return }
            googleCalendarStatus = GoogleCalendarConnectionStatus(
                connected: false,
                accountEmail: nil,
                scopes: [],
                settings: nil,
                connectedAt: nil,
                lastSyncedAt: nil
            )
        } catch {
            guard activeUserID == requestedUserID,
                  googleCalendarRequestGeneration == requestGeneration
            else { return }
            googleCalendarErrorMessage = googleCalendarFriendlyMessage(for: error)
        }
    }

    @discardableResult
    func start(
        activity: StudyActivityKind,
        source: StudyActivitySource,
        name: String? = nil,
        at date: Date = .now
    ) -> Bool {
        guard let userID = activeUserID else { return false }
        let operation = StorageWriteOperation.start(
            activity: activity,
            source: source,
            name: name,
            replacingSessionID: active?.clientSessionID
        )
        guard storageMode == .persistent else {
            setStorageWriteError(
                StorageWriteUnavailableError(domain: .studyTime),
                for: operation
            )
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
                setStorageWriteError(StudyTimeStoreError.sessionUnavailable, for: operation)
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
            clearStorageWriteError(for: operation)
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
            setStorageWriteError(error, for: operation)
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
        guard var current = active, current.activity == .cardCreation else { return true }
        let operation = StorageWriteOperation.addCreatedCards(
            clientSessionID: current.clientSessionID,
            count: count
        )
        guard let record = record(clientSessionID: current.clientSessionID) else {
            loadLocalSessions()
            setStorageWriteError(StudyTimeStoreError.sessionUnavailable, for: operation)
            return false
        }
        let previousCount = current.cardsCreated
        current.cardsCreated += count
        record.cardsCreated = current.cardsCreated
        do {
            try contextSaver.save()
            localMutationGeneration += 1
            active = current
            clearStorageWriteError(for: operation)
            return true
        } catch {
            context.rollback()
            current.cardsCreated = previousCount
            active = current
            setStorageWriteError(error, for: operation)
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
        let operation = StorageWriteOperation.recordCompleted(
            activity: activity,
            source: source,
            name: name,
            startedAt: startedAt,
            duration: boundedDuration
        )
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
            setStorageWriteError(error, for: operation)
            throw error
        }
        localMutationGeneration += 1
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        if let completedSession = record.session {
            upsertEditableSession(completedSession)
        }
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
        guard session.isEditable else {
            throw StudyTimeStoreError.readOnlySession
        }
        guard let record = record(clientSessionID: session.clientSessionId) else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        guard let previousSession = record.session else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        let operation = StorageWriteOperation.update(
            clientSessionID: session.clientSessionId
        )
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
            // Preserve the complete pre-edit local transaction, including a
            // dangling calendar link. A retry will observe EventKit's missing
            // event again and persist the self-heal with the requested edit.
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
            setStorageWriteError(error, for: operation)
            throw error
        }
        localMutationGeneration += 1
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        if let updatedSession = record.session {
            upsertEditableSession(updatedSession)
        }
        await pushPending()
        await refreshAnalytics()
        return calendarWarning
    }

    func delete(session: StudyActivitySession) async throws {
        try requirePersistentWrites()
        guard session.isEditable else {
            throw StudyTimeStoreError.readOnlySession
        }
        guard let record = record(clientSessionID: session.clientSessionId) else {
            throw StudyTimeStoreError.sessionUnavailable
        }
        let operation = StorageWriteOperation.delete(
            clientSessionID: session.clientSessionId
        )
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
            setStorageWriteError(error, for: operation)
            throw error
        }
        localMutationGeneration += 1
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        removeEditableSession(clientSessionID: session.clientSessionId)
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
                _ = try mergeRemoteSessions(remote, userID: userID)
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
                persistSnapshot()
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

    private func mergeRemoteSessions(
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
        return remote.compactMap { recordsByID[$0.clientSessionId]?.session }
    }

    func deleteLocalData(userID: Int) throws {
        localMutationGeneration += 1
        snapshotCache.remove(userID: userID)
        try context.delete(
            model: LocalStudyActivitySession.self,
            where: #Predicate { $0.userID == userID }
        )
        if activeUserID == userID {
            sessions = []
            editableSessions = []
            editableSessionsNextCursor = nil
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
        let operation = StorageWriteOperation.finish(
            clientSessionID: current.clientSessionID
        )
        guard let record = record(clientSessionID: current.clientSessionID) else {
            loadLocalSessions()
            setStorageWriteError(StudyTimeStoreError.sessionUnavailable, for: operation)
            return false
        }
        complete(record, from: current, at: date)
        do {
            try contextSaver.save()
        } catch {
            context.rollback()
            active = current
            setStorageWriteError(error, for: operation)
            return false
        }
        localMutationGeneration += 1
        active = nil
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        if let completedSession = record.session {
            upsertEditableSession(completedSession)
        }
        if enqueueSync {
            Task {
                await pushPending()
                await refreshAnalytics()
            }
        }
        return true
    }

    private func setStorageWriteError(
        _ error: any Error,
        for operation: StorageWriteOperation
    ) {
        storageWriteErrorMessage = error.localizedDescription
        storageWriteErrorOperation = operation
    }

    private func clearStorageWriteError(for operation: StorageWriteOperation? = nil) {
        guard operation == nil || storageWriteErrorOperation == operation else { return }
        storageWriteErrorMessage = nil
        storageWriteErrorOperation = nil
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
                persistSnapshot()
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
                    value: "2"
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

    private func upsertEditableSession(_ session: StudyActivitySession) {
        guard session.isEditable else { return }
        editableSessions.removeAll { $0.clientSessionId == session.clientSessionId }
        editableSessions.append(session)
        editableSessions.sort { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.clientSessionId > rhs.clientSessionId
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    private func removeEditableSession(clientSessionID: String) {
        editableSessions.removeAll { $0.clientSessionId == clientSessionID }
    }

    private func restoreSnapshot(userID: Int) {
        let timeZone = TimeZone.autoupdatingCurrent.identifier
        guard let snapshot = snapshotCache.load(userID: userID, timeZone: timeZone) else { return }
        let age = now().timeIntervalSince(snapshot.savedAt)
        guard age >= 0, age < 7 * 86_400 else { return }

        if let cachedAnalytics = snapshot.analytics,
           cachedAnalytics.anchorDate == analyticsAnchorString(from: now())
        {
            analytics = cachedAnalytics
            analyticsCache[cachedAnalytics.anchorDate] = cachedAnalytics
        }
        if let cachedRecap = snapshot.weeklyRecap,
           recapMatchesMostRecentCompletedWeek(cachedRecap, timeZone: timeZone)
        {
            weeklyRecap = cachedRecap
            weeklyRecapRefreshedAt = snapshot.weeklyRecapRefreshedAt ?? snapshot.savedAt
        }
    }

    private func persistSnapshot(
        timeZone: String = TimeZone.autoupdatingCurrent.identifier
    ) {
        guard let userID = activeUserID else { return }
        snapshotCache.save(
            StudyTimeSnapshot(
                savedAt: now(),
                analytics: analytics,
                weeklyRecap: weeklyRecap,
                weeklyRecapRefreshedAt: weeklyRecapRefreshedAt
            ),
            userID: userID,
            timeZone: timeZone
        )
    }

    private func recapMatchesMostRecentCompletedWeek(
        _ recap: WeeklyStudyRecap,
        timeZone identifier: String
    ) -> Bool {
        guard let timeZone = TimeZone(identifier: identifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        guard let currentWeekStart = calendar.dateInterval(
            of: .weekOfYear,
            for: now()
        )?.start else { return false }
        return abs(recap.week.endsAt.timeIntervalSince(currentWeekStart)) < 1
    }

    private func pendingEditableSessions(userID: Int) -> [StudyActivitySession] {
        let descriptor = FetchDescriptor<LocalStudyActivitySession>(
            predicate: #Predicate {
                $0.userID == userID && $0.syncPending && !$0.isTombstone
            }
        )
        return (try? context.fetch(descriptor))?
            .compactMap(\.session)
            .filter(\.isEditable) ?? []
    }

    private func mergeCompletedSessionsIntoLocalView(_ merged: [StudyActivitySession]) {
        let mergedIDs = Set(merged.map(\.clientSessionId))
        sessions.removeAll { mergedIDs.contains($0.clientSessionId) }
        sessions.append(contentsOf: merged)
        sessions.sort { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.clientSessionId > rhs.clientSessionId
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    private func sortedUniqueEditableSessions(
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
