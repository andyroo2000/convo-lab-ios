import Foundation
import SwiftData

@Observable
final class StudyTimeStore {
    private static let automaticRecoveryLimit: TimeInterval = 5 * 60

    typealias ActiveSession = StudyTimeActiveSession
    private typealias StorageWriteOperation = StudyTimeStorageWriteOperation

    private let api: APIClient
    private let mutationRepository: StudyTimeSessionMutationRepository
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
    private var storageWriteErrorOperation: StudyTimeStorageWriteOperation?
    private(set) var syncErrorMessage: String?
    private(set) var googleCalendarStatus: GoogleCalendarConnectionStatus?
    private(set) var googleCalendarStatusRefreshedAt: Date?
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
        mutationRepository = StudyTimeSessionMutationRepository(
            api: api,
            context: context,
            storageMode: storageMode,
            contextSaver: contextSaver,
            calendar: calendar
        )
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
        googleCalendarStatusRefreshedAt = nil
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
        googleCalendarStatusRefreshedAt = nil
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
            googleCalendarStatusRefreshedAt = now()
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
            // This paginated list is presentation data, not a replica refresh. Persisting
            // each page here makes SwiftData save on the main actor while the user is
            // trying to scroll the Time tab. Overlay any unsent local mutations, but only
            // materialize a server entry in SwiftData if the user edits or deletes it.
            let resolvedItems = try mutationRepository.resolvedEditableSessions(
                page.items,
                userID: requestedUserID
            )
            if reset {
                editableSessions = StudyTimeEditableSessionProjection.sortedUnique(
                    resolvedItems
                        + mutationRepository.pendingEditableSessions(userID: requestedUserID)
                )
            } else {
                let existingIDs = Set(editableSessions.map(\.clientSessionId))
                editableSessions.append(contentsOf: resolvedItems.filter {
                    !existingIDs.contains($0.clientSessionId)
                })
                editableSessions = StudyTimeEditableSessionProjection.sortedUnique(
                    editableSessions
                )
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
        do {
            try mutationRepository.requirePersistentWrites()
        } catch {
            setStorageWriteError(error, for: operation)
            return false
        }
        if active?.activity == activity, active?.source == source, active?.name == name {
            return true
        }
        if active?.source == .manual, source == .automatic {
            return true
        }
        let previousActive = active
        do {
            let result = try mutationRepository.start(
                replacing: previousActive,
                activity: activity,
                source: source,
                name: name,
                at: date,
                userID: userID
            )
            localMutationGeneration += 1
            active = result.active
            clearStorageWriteError(for: operation)
            if result.completedPreviousSession {
                loadLocalSessions()
                Task {
                    await pushPending()
                    await refreshAnalytics()
                }
            }
            return true
        } catch StudyTimeSessionMutationError.sessionUnavailable {
            loadLocalSessions()
            setStorageWriteError(
                StudyTimeSessionMutationError.sessionUnavailable,
                for: operation
            )
            return false
        } catch {
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
        guard let userID = activeUserID else {
            setStorageWriteError(
                StudyTimeSessionMutationError.sessionUnavailable,
                for: operation
            )
            return false
        }
        do {
            current = try mutationRepository.addCreatedCards(
                count,
                to: current,
                userID: userID
            )
            localMutationGeneration += 1
            active = current
            clearStorageWriteError(for: operation)
            return true
        } catch StudyTimeSessionMutationError.sessionUnavailable {
            loadLocalSessions()
            setStorageWriteError(
                StudyTimeSessionMutationError.sessionUnavailable,
                for: operation
            )
            return false
        } catch {
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
        try mutationRepository.requirePersistentWrites()
        guard let userID = activeUserID else { return nil }
        let operation = StorageWriteOperation.recordCompleted(
            activity: activity,
            source: source,
            name: name,
            startedAt: startedAt,
            duration: max(0, min(duration, 86_400))
        )
        let result: StudyTimeSessionMutationRepository.CompletedMutation
        do {
            result = try await mutationRepository.recordCompleted(
                activity: activity,
                source: source,
                name: name,
                startedAt: startedAt,
                duration: duration,
                addToCalendar: addToCalendar,
                userID: userID
            )
        } catch {
            setStorageWriteError(error, for: operation)
            throw error
        }
        localMutationGeneration += 1
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        if let completedSession = result.session {
            editableSessions = StudyTimeEditableSessionProjection.upserting(
                completedSession,
                in: editableSessions
            )
        }
        await pushPending()
        await refreshAnalytics()
        return result.calendarWarning
    }

    func update(
        session: StudyActivitySession,
        activity: StudyActivityKind,
        name: String?,
        startedAt: Date,
        duration: TimeInterval
    ) async throws -> String? {
        try mutationRepository.requirePersistentWrites()
        guard let userID = activeUserID else {
            throw StudyTimeSessionMutationError.sessionUnavailable
        }
        let operation = StorageWriteOperation.update(
            clientSessionID: session.clientSessionId
        )
        let result: StudyTimeSessionMutationRepository.CompletedMutation
        do {
            result = try await mutationRepository.update(
                session: session,
                activity: activity,
                name: name,
                startedAt: startedAt,
                duration: duration,
                userID: userID
            )
        } catch {
            loadLocalSessions()
            setStorageWriteError(error, for: operation)
            throw error
        }
        localMutationGeneration += 1
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        if let updatedSession = result.session {
            editableSessions = StudyTimeEditableSessionProjection.upserting(
                updatedSession,
                in: editableSessions
            )
        }
        await pushPending()
        await refreshAnalytics()
        return result.calendarWarning
    }

    func delete(session: StudyActivitySession) async throws {
        try mutationRepository.requirePersistentWrites()
        guard let userID = activeUserID else {
            throw StudyTimeSessionMutationError.sessionUnavailable
        }
        let operation = StorageWriteOperation.delete(
            clientSessionID: session.clientSessionId
        )
        do {
            try mutationRepository.delete(session: session, userID: userID)
        } catch {
            loadLocalSessions()
            setStorageWriteError(error, for: operation)
            throw error
        }
        localMutationGeneration += 1
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        editableSessions = StudyTimeEditableSessionProjection.removing(
            clientSessionID: session.clientSessionId,
            from: editableSessions
        )
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
                _ = try mutationRepository.mergeRemoteSessions(remote, userID: userID)
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

    func deleteLocalData(userID: Int) throws {
        localMutationGeneration += 1
        snapshotCache.remove(userID: userID)
        try mutationRepository.deleteLocalData(userID: userID)
        if activeUserID == userID {
            sessions = []
            editableSessions = []
            editableSessionsNextCursor = nil
            analytics = nil
            analyticsCache = [:]
            analyticsCacheGeneration += 1
            active = nil
        }
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
        guard let userID = activeUserID else {
            setStorageWriteError(
                StudyTimeSessionMutationError.sessionUnavailable,
                for: operation
            )
            return false
        }
        let completedSession: StudyActivitySession?
        do {
            completedSession = try mutationRepository.finish(
                current,
                at: date,
                userID: userID
            )
        } catch StudyTimeSessionMutationError.sessionUnavailable {
            loadLocalSessions()
            setStorageWriteError(
                StudyTimeSessionMutationError.sessionUnavailable,
                for: operation
            )
            return false
        } catch {
            active = current
            setStorageWriteError(error, for: operation)
            return false
        }
        localMutationGeneration += 1
        active = nil
        clearStorageWriteError(for: operation)
        loadLocalSessions()
        if let completedSession {
            editableSessions = StudyTimeEditableSessionProjection.upserting(
                completedSession,
                in: editableSessions
            )
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
        let result = await mutationRepository.pushPending(
            userID: userID,
            mutationGeneration: mutationGeneration
        ) { [weak self] userID, generation in
            self?.isCurrentMutation(userID: userID, generation: generation) == true
        }
        guard !result.becameStale,
              isCurrentMutation(userID: userID, generation: mutationGeneration)
        else { return }
        syncErrorMessage = result.failures.first
        loadLocalSessions()
    }

    private func isCurrentMutation(userID: Int, generation: Int) -> Bool {
        activeUserID == userID && localMutationGeneration == generation
    }

    private func loadLocalSessions(recoverAbandonedAutomatic: Bool = false) {
        guard let userID = activeUserID else { return }
        guard let loaded = mutationRepository.loadLocalSessions(userID: userID) else {
            return
        }
        sessions = loaded.sessions
        active = loaded.active
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

}
