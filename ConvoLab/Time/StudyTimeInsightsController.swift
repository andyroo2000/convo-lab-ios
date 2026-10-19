import Foundation

@MainActor
@Observable
final class StudyTimeInsightsController {
    struct RefreshRequest {
        let userID: Int
        let generation: Int
        let anchorDate: Date
        let cacheGeneration: Int
        let context: StudyTimeAnalyticsCalendar
    }

    struct RefreshResult {
        let loaded: Bool
        let failureMessage: String?
    }

    private let api: APIClient
    private let weeklyRecapService: any WeeklyStudyRecapServing
    private let snapshotCache: any StudyTimeSnapshotCaching
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private var context: StudyTimeAnalyticsCalendar
    private var periodCache = StudyTimePeriodCache()
    private let requests = StudyTimeAnalyticsRequests()
    private var revalidationTask: Task<Void, Never>?

    private(set) var analytics: StudyTimeAnalytics?
    var analyticsCache: [String: StudyTimeAnalytics] { periodCache.analytics }
    private(set) var analyticsCacheGeneration = 0
    private(set) var weeklyRecap: WeeklyStudyRecap?
    private(set) var weeklyRecapIsLoading = false
    private(set) var weeklyRecapErrorMessage: String?

    private var activeUserID: Int?
    private var analyticsRequestGeneration = 0
    private var weeklyRecapRequestGeneration = 0
    private var weeklyRecapRefreshedAt: Date?
    private var requestedAnalyticsAnchor: Date?

    init(
        api: APIClient,
        weeklyRecapService: (any WeeklyStudyRecapServing)? = nil,
        snapshotCache: (any StudyTimeSnapshotCaching)? = nil,
        now: @escaping () -> Date = { .now },
        timeZone: @escaping () -> TimeZone = { .current }
    ) {
        self.api = api
        self.weeklyRecapService = weeklyRecapService ?? LiveWeeklyStudyRecapService(api: api)
        self.snapshotCache = snapshotCache ?? UserDefaultsStudyTimeSnapshotCache()
        self.now = now
        self.timeZone = timeZone
        context = StudyTimeAnalyticsCalendar(timeZone: timeZone())
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        analyticsRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        analytics = nil
        invalidateAnalyticsCache()
        weeklyRecap = nil
        weeklyRecapErrorMessage = nil
        weeklyRecapIsLoading = false
        weeklyRecapRefreshedAt = nil
        activeUserID = userID
        restoreSnapshot(userID: userID)
    }

    func invalidateRequestsForDeactivation() {
        analyticsRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        requests.cancelAll()
        revalidationTask?.cancel()
        activeUserID = nil
    }

    func deactivate() {
        if activeUserID != nil {
            invalidateRequestsForDeactivation()
        }
        analytics = nil
        invalidateAnalyticsCache()
        weeklyRecap = nil
        weeklyRecapErrorMessage = nil
        weeklyRecapIsLoading = false
        weeklyRecapRefreshedAt = nil
    }

    func deleteLocalData(userID: Int) {
        snapshotCache.remove(userID: userID)
        guard activeUserID == userID else { return }
        analyticsRequestGeneration += 1
        analytics = nil
        invalidateAnalyticsCache()
    }

    func loadWeeklyRecap(
        timeZone: String = TimeZone.autoupdatingCurrent.identifier,
        force: Bool = false
    ) async {
        guard let requestedUserID = activeUserID, !weeklyRecapIsLoading else { return }
        if !force, let weeklyRecapRefreshedAt {
            let age = now().timeIntervalSince(weeklyRecapRefreshedAt)
            if age >= 0, age < 15 * 60 { return }
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
            guard activeUserID == requestedUserID,
                  weeklyRecapRequestGeneration == generation
            else { return }
            weeklyRecap = value
            weeklyRecapRefreshedAt = now()
            persistSnapshot(timeZone: timeZone)
        } catch {
            guard activeUserID == requestedUserID,
                  weeklyRecapRequestGeneration == generation
            else { return }
            weeklyRecapErrorMessage = "Couldn’t load your weekly recap. Pull to refresh and try again."
        }
    }

    @discardableResult
    func loadAnalytics(anchorDate: Date, range: StudyTimeRange? = nil) async -> RefreshResult {
        ensureContext()
        guard !Task.isCancelled else { return .init(loaded: false, failureMessage: nil) }
        if selectCachedAnalytics(anchorDate: anchorDate, range: range) {
            return .init(loaded: true, failureMessage: nil)
        }
        guard let request = prepareSelection(anchorDate: anchorDate) else {
            return .init(loaded: false, failureMessage: nil)
        }
        return await finishRefresh(request)
    }

    func cachedAnalytics(anchorDate: Date, range: StudyTimeRange? = nil) -> StudyTimeAnalytics? {
        guard activeUserID != nil, context.timeZone == timeZone() else { return nil }
        return periodCache.entry(anchor: anchorDate, range: range, context: context)?.value
    }

    @discardableResult
    func prefetchAnalytics(anchorDate: Date, range: StudyTimeRange? = nil) async -> RefreshResult {
        ensureContext()
        guard let request = requestContext(anchorDate: anchorDate) else {
            return .init(loaded: false, failureMessage: nil)
        }
        if periodCache.entry(anchor: anchorDate, range: range, context: context)?.generation
            == analyticsCacheGeneration {
            return .init(loaded: true, failureMessage: nil)
        }
        do {
            let fetched = try await fetchAnalytics(request)
            guard isCurrentContext(request) else { return .init(loaded: false, failureMessage: nil) }
            cache(fetched, for: request)
            return .init(loaded: true, failureMessage: nil)
        } catch {
            return failure(error, for: request)
        }
    }

    @discardableResult
    func selectCachedAnalytics(anchorDate: Date, range: StudyTimeRange? = nil) -> Bool {
        ensureContext()
        guard activeUserID != nil, !Task.isCancelled,
              let entry = periodCache.entry(anchor: anchorDate, range: range, context: context)
        else { return false }
        analyticsRequestGeneration += 1
        revalidationTask?.cancel()
        publish(entry.value)
        if entry.generation != analyticsCacheGeneration { revalidate(anchorDate: anchorDate) }
        return true
    }

    func prepareRefresh(anchorDate: Date? = nil) -> RefreshRequest? {
        ensureContext()
        guard activeUserID != nil, !Task.isCancelled else { return nil }
        // Keep usable snapshots on screen. The new epoch prevents older network
        // completions from marking them fresh after a sync or mutation.
        advanceCacheGeneration()
        return prepareSelection(anchorDate: anchorDate ?? requestedAnalyticsAnchor ?? now())
    }

    func finishRefresh(_ request: RefreshRequest) async -> RefreshResult {
        guard isCurrentContext(request) else { return .init(loaded: false, failureMessage: nil) }
        do {
            let fetched = try await fetchAnalytics(request)
            guard isCurrentContext(request) else { return .init(loaded: false, failureMessage: nil) }
            cache(fetched, for: request)
            guard analyticsRequestGeneration == request.generation else {
                return .init(loaded: false, failureMessage: nil)
            }
            publish(fetched)
            persistSnapshot()
            return .init(loaded: true, failureMessage: nil)
        } catch {
            guard analyticsRequestGeneration == request.generation else {
                return .init(loaded: false, failureMessage: nil)
            }
            return failure(error, for: request)
        }
    }

    func refreshAnalytics(anchorDate: Date? = nil) async -> RefreshResult {
        guard let request = prepareRefresh(anchorDate: anchorDate) else {
            return .init(loaded: false, failureMessage: nil)
        }
        return await finishRefresh(request)
    }

    private func prepareSelection(anchorDate: Date) -> RefreshRequest? {
        analyticsRequestGeneration += 1
        revalidationTask?.cancel()
        return requestContext(anchorDate: anchorDate)
    }

    private func requestContext(anchorDate: Date) -> RefreshRequest? {
        guard let userID = activeUserID, !Task.isCancelled else { return nil }
        return .init(userID: userID, generation: analyticsRequestGeneration, anchorDate: anchorDate,
                     cacheGeneration: analyticsCacheGeneration, context: context)
    }

    private func isCurrentContext(_ request: RefreshRequest) -> Bool {
        !Task.isCancelled && activeUserID == request.userID
            && analyticsCacheGeneration == request.cacheGeneration
            && context == request.context && context.timeZone == timeZone()
    }

    private func failure(_ error: Error, for request: RefreshRequest) -> RefreshResult {
        .init(loaded: false, failureMessage: isCurrentContext(request) ? error.localizedDescription : nil)
    }

    private func cache(_ value: StudyTimeAnalytics, for request: RefreshRequest) {
        periodCache.insert(value, requestedAnchor: request.context.anchor(request.anchorDate),
                           generation: request.cacheGeneration)
    }

    private func publish(_ value: StudyTimeAnalytics) {
        analytics = value
        let anchor = context.date(value.anchorDate)
        requestedAnalyticsAnchor = anchor.flatMap {
            context.calendar.isDate($0, inSameDayAs: now()) ? nil : $0
        }
    }

    private func revalidate(anchorDate: Date) {
        guard let request = requestContext(anchorDate: anchorDate) else { return }
        revalidationTask = Task {
            _ = await self.finishRefresh(request)
            if self.analyticsRequestGeneration == request.generation { self.revalidationTask = nil }
        }
    }

    private func fetchAnalytics(_ request: RefreshRequest) async throws -> StudyTimeAnalytics {
        guard isCurrentContext(request) else { throw CancellationError() }
        let anchor = request.context.anchor(request.anchorDate)
        let api = api
        let token = api.accessToken
        return try await requests.value(for: anchor) {
            try Task.checkCancellation()
            return try await api.request(
                "/api/study/activity-analytics",
                query: [
                    URLQueryItem(name: "timezone", value: request.context.timeZone.identifier),
                    URLQueryItem(name: "weekStartsOn", value: String(request.context.weekStartsOn)),
                    URLQueryItem(name: "anchorDate", value: anchor),
                ], authorizationToken: token, response: StudyTimeAnalytics.self
            )
        }
    }

    private func advanceCacheGeneration() {
        analyticsCacheGeneration += 1
        requests.cancelAll()
        revalidationTask?.cancel()
        revalidationTask = nil
    }

    private func invalidateAnalyticsCache() {
        advanceCacheGeneration()
        periodCache = StudyTimePeriodCache()
    }

    private func ensureContext() {
        let current = StudyTimeAnalyticsCalendar(timeZone: timeZone())
        guard context != current else { return }
        context = current
        analyticsRequestGeneration += 1
        analytics = nil
        requestedAnalyticsAnchor = nil
        invalidateAnalyticsCache()
    }

    private func restoreSnapshot(userID: Int) {
        let timeZone = TimeZone.autoupdatingCurrent.identifier
        guard let snapshot = snapshotCache.load(userID: userID, timeZone: timeZone) else { return }
        let age = now().timeIntervalSince(snapshot.savedAt)
        guard age >= 0, age < 7 * 86_400 else { return }
        if let cachedAnalytics = snapshot.analytics,
           cachedAnalytics.anchorDate == context.anchor(now())
        {
            analytics = cachedAnalytics
            periodCache.insert(cachedAnalytics, requestedAnchor: cachedAnalytics.anchorDate,
                               generation: analyticsCacheGeneration)
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
