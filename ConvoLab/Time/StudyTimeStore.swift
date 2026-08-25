import Foundation
import SwiftData

@Observable
final class StudyTimeStore {
    private static let automaticRecoveryLimit: TimeInterval = 5 * 60

    typealias ActiveSession = StudyTimeActiveSession
    private typealias StorageWriteOperation = StudyTimeStorageWriteOperation

    private let api: APIClient
    private let mutationRepository: StudyTimeSessionMutationRepository
    private let synchronizationCoordinator: StudyTimeSynchronizationCoordinator
    private let insightsController: StudyTimeInsightsController
    private let googleCalendar: any GoogleCalendarConnectionServing
    private let googleCalendarAuthorizer: any GoogleCalendarAuthorizing
    private let now: () -> Date
    private(set) var sessions: [StudyActivitySession] = []
    private(set) var editableSessions: [StudyActivitySession] = []
    private(set) var editableSessionsNextCursor: String?
    private(set) var editableSessionsIsLoading = false
    private(set) var editableSessionsErrorMessage: String?
    var analytics: StudyTimeAnalytics? { insightsController.analytics }
    var analyticsCache: [String: StudyTimeAnalytics] { insightsController.analyticsCache }
    var analyticsCacheGeneration: Int { insightsController.analyticsCacheGeneration }
    private(set) var active: ActiveSession?
    private(set) var storageWriteErrorMessage: String?
    private var storageWriteErrorOperation: StudyTimeStorageWriteOperation?
    private(set) var syncErrorMessage: String?
    private(set) var googleCalendarStatus: GoogleCalendarConnectionStatus?
    private(set) var googleCalendarStatusRefreshedAt: Date?
    private(set) var googleCalendarIsLoading = false
    private(set) var googleCalendarIsWorking = false
    private(set) var googleCalendarErrorMessage: String?
    var weeklyRecap: WeeklyStudyRecap? { insightsController.weeklyRecap }
    var weeklyRecapIsLoading: Bool { insightsController.weeklyRecapIsLoading }
    var weeklyRecapErrorMessage: String? { insightsController.weeklyRecapErrorMessage }
    private var activeUserID: Int?
    private var googleCalendarRequestGeneration = 0

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
        let mutationRepository = StudyTimeSessionMutationRepository(
            api: api,
            context: context,
            storageMode: storageMode,
            contextSaver: contextSaver,
            calendar: calendar
        )
        self.mutationRepository = mutationRepository
        let insightsController = StudyTimeInsightsController(
            api: api,
            weeklyRecapService: weeklyRecapService,
            snapshotCache: snapshotCache,
            now: now
        )
        self.insightsController = insightsController
        synchronizationCoordinator = StudyTimeSynchronizationCoordinator(
            api: api,
            repository: mutationRepository,
            insights: insightsController
        )
        self.googleCalendar = googleCalendar ?? LiveGoogleCalendarConnectionService(api: api)
        self.googleCalendarAuthorizer = googleCalendarAuthorizer
            ?? LiveGoogleCalendarAuthorizer()
        self.now = now
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        synchronizationCoordinator.activate(userID: userID)
        insightsController.activate(userID: userID)
        googleCalendarRequestGeneration += 1
        clearStorageWriteError()
        googleCalendarStatus = nil
        googleCalendarStatusRefreshedAt = nil
        googleCalendarErrorMessage = nil
        googleCalendarIsLoading = false
        googleCalendarIsWorking = false
        activeUserID = userID
        loadLocalSessions(recoverAbandonedAutomatic: true)
        editableSessions = Array(
            sessions.filter(\.isEditable).sorted { $0.startedAt > $1.startedAt }.prefix(20)
        )
        editableSessionsNextCursor = nil
        editableSessionsErrorMessage = nil
        editableSessionsIsLoading = false
    }

    @discardableResult
    func deactivate(at date: Date = .now) async -> Bool {
        synchronizationCoordinator.markLocalMutation()
        insightsController.invalidateRequestsForDeactivation()
        googleCalendarRequestGeneration += 1
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
        synchronizationCoordinator.deactivate()
        insightsController.deactivate()
        active = nil
        clearStorageWriteError()
        syncErrorMessage = nil
        googleCalendarStatus = nil
        googleCalendarStatusRefreshedAt = nil
        googleCalendarErrorMessage = nil
        googleCalendarIsLoading = false
        googleCalendarIsWorking = false
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
        await insightsController.loadWeeklyRecap(timeZone: timeZone, force: force)
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
            synchronizationCoordinator.markLocalMutation()
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
            synchronizationCoordinator.markLocalMutation()
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
        synchronizationCoordinator.markLocalMutation()
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
        guard session.isEditable else {
            throw StudyTimeSessionMutationError.readOnlySession
        }
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
        } catch let error as StudyTimeMutationPersistenceError {
            loadLocalSessions()
            setStorageWriteError(error, for: operation)
            throw error.underlying
        }
        synchronizationCoordinator.markLocalMutation()
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
        guard session.isEditable else {
            throw StudyTimeSessionMutationError.readOnlySession
        }
        guard let userID = activeUserID else {
            throw StudyTimeSessionMutationError.sessionUnavailable
        }
        let operation = StorageWriteOperation.delete(
            clientSessionID: session.clientSessionId
        )
        do {
            try mutationRepository.delete(session: session, userID: userID)
        } catch let error as StudyTimeMutationPersistenceError {
            loadLocalSessions()
            setStorageWriteError(error, for: operation)
            throw error.underlying
        }
        synchronizationCoordinator.markLocalMutation()
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
        guard let requestedUserID = activeUserID,
              let outcome = await synchronizationCoordinator.synchronize(),
              synchronizationCoordinator.isCurrent(userID: requestedUserID),
              !outcome.becameStale
        else { return }
        applyLoadedSessions(outcome.loadedSessions)
        syncErrorMessage = outcome.failureMessage
    }

    func deleteLocalData(userID: Int) throws {
        synchronizationCoordinator.markLocalMutation()
        insightsController.deleteLocalData(userID: userID)
        try mutationRepository.deleteLocalData(userID: userID)
        if activeUserID == userID {
            sessions = []
            editableSessions = []
            editableSessionsNextCursor = nil
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
        synchronizationCoordinator.markLocalMutation()
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
        guard let requestedUserID = activeUserID,
              let outcome = await synchronizationCoordinator.pushPending(),
              synchronizationCoordinator.isCurrent(userID: requestedUserID),
              !outcome.becameStale
        else { return }
        syncErrorMessage = outcome.failureMessage
        applyLoadedSessions(outcome.loadedSessions)
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

    private func applyLoadedSessions(
        _ loaded: StudyTimeSessionMutationRepository.LoadedSessions?
    ) {
        guard let loaded else { return }
        sessions = loaded.sessions
        active = loaded.active
    }

    @discardableResult
    func loadAnalytics(anchorDate: Date) async -> Bool {
        let result = await insightsController.loadAnalytics(anchorDate: anchorDate)
        if let failure = result.failureMessage, syncErrorMessage == nil {
            syncErrorMessage = failure
        }
        return result.loaded
    }

    func cachedAnalytics(anchorDate: Date) -> StudyTimeAnalytics? {
        insightsController.cachedAnalytics(anchorDate: anchorDate)
    }

    @discardableResult
    func prefetchAnalytics(
        anchorDate: Date,
        reportFailure: Bool = false
    ) async -> Bool {
        let result = await insightsController.prefetchAnalytics(anchorDate: anchorDate)
        if reportFailure, let failure = result.failureMessage {
            syncErrorMessage = failure
        }
        return result.loaded
    }

    @discardableResult
    func selectCachedAnalytics(anchorDate: Date) -> Bool {
        insightsController.selectCachedAnalytics(anchorDate: anchorDate)
    }

    @discardableResult
    private func refreshAnalytics(anchorDate: Date? = nil) async -> Bool {
        let result = await insightsController.refreshAnalytics(anchorDate: anchorDate)
        if let failure = result.failureMessage, syncErrorMessage == nil {
            syncErrorMessage = failure
        }
        return result.loaded
    }

}
