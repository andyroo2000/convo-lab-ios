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
        let range: StudyTimeRange?
        let authorizationToken: String?
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
    private let prefetch = StudyTimeAnalyticsPrefetch()
    private var viewport = StudyTimeAnalyticsViewport()
    private var contextToken: String?

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
    private var requestedAnalyticsRange: StudyTimeRange? = .week

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
        contextToken = api.accessToken
    }

    func activate(userID: Int) {
        ensureContext()
        guard activeUserID != userID else { return }
        analyticsRequestGeneration += 1
        weeklyRecapRequestGeneration += 1
        requestedAnalyticsAnchor = nil
        requestedAnalyticsRange = .week
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
        prefetch.cancel()
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
        weeklyRecapRequestGeneration += 1
        analytics = nil
        requestedAnalyticsAnchor = nil
        weeklyRecap = nil
        weeklyRecapIsLoading = false
        weeklyRecapErrorMessage = nil
        weeklyRecapRefreshedAt = nil
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
        guard let request = prepareSelection(anchorDate: anchorDate, range: range) else {
            return .init(loaded: false, failureMessage: nil)
        }
        let result = await finishRefresh(request)
        if shouldRetrySelection(request) { return await loadAnalytics(anchorDate: anchorDate, range: range) }
        return result
    }

    func cachedAnalytics(anchorDate: Date, range: StudyTimeRange? = nil) -> StudyTimeAnalytics? {
        guard activeUserID != nil, context.timeZone == timeZone(), contextToken == api.accessToken else { return nil }
        return availableEntry(anchorDate: anchorDate, range: range)?.value
    }

    @discardableResult
    func prefetchAnalytics(
        anchorDate: Date, range: StudyTimeRange? = nil, speculative: Bool = false
    ) async -> RefreshResult {
        ensureContext()
        guard let request = requestContext(anchorDate: anchorDate, range: range) else {
            return .init(loaded: false, failureMessage: nil)
        }
        if let entry = availableEntry(anchorDate: anchorDate, range: range), isFresh(entry) {
            return .init(loaded: true, failureMessage: nil)
        }
        if !speculative { prefetch.beginForeground() }
        defer { if !speculative { prefetch.endForeground() } }
        do {
            let fetched = try await fetchAnalytics(request)
            guard isCurrentContext(request) else {
                return await retryPrefetch(request, speculative: speculative)
            }
            cache(fetched, for: request)
            return .init(loaded: true, failureMessage: nil)
        } catch {
            if shouldRetrySelection(request) { return await retryPrefetch(request, speculative: speculative) }
            return failure(error, for: request)
        }
    }

    private func retryPrefetch(_ request: RefreshRequest, speculative: Bool) async -> RefreshResult {
        guard !speculative, shouldRetrySelection(request) else { return .init(loaded: false, failureMessage: nil) }
        return await prefetchAnalytics(anchorDate: request.anchorDate, range: request.range)
    }

    @discardableResult
    func selectCachedAnalytics(anchorDate: Date, range: StudyTimeRange? = nil) -> Bool {
        ensureContext()
        guard activeUserID != nil, !Task.isCancelled,
              let entry = availableEntry(anchorDate: anchorDate, range: range)
        else { return false }
        analyticsRequestGeneration += 1
        revalidationTask?.cancel()
        requestedAnalyticsRange = range
        publish(entry.value)
        if !isFresh(entry) { revalidate(anchorDate: anchorDate, range: range) }
        return true
    }

    func prepareRefresh(anchorDate: Date? = nil) -> RefreshRequest? {
        ensureContext()
        guard activeUserID != nil, !Task.isCancelled else { return nil }
        // Keep usable snapshots on screen. The new epoch prevents older network
        // completions from marking them fresh after a sync or mutation.
        advanceCacheGeneration()
        if let anchorDate { return prepareSelection(anchorDate: anchorDate, range: requestedAnalyticsRange) }
        return requestContext(anchorDate: requestedAnalyticsAnchor ?? now(), range: requestedAnalyticsRange)
    }

    func finishRefresh(_ request: RefreshRequest) async -> RefreshResult {
        guard isCurrentContext(request) else { return .init(loaded: false, failureMessage: nil) }
        prefetch.beginForeground()
        defer { prefetch.endForeground() }
        do {
            let fetched = try await fetchAnalytics(request)
            guard isCurrentContext(request) else { return .init(loaded: false, failureMessage: nil) }
            cache(fetched, for: request)
            guard analyticsRequestGeneration == request.generation else {
                return .init(loaded: false, failureMessage: nil)
            }
            publish(fetched)
            return .init(loaded: true, failureMessage: nil)
        } catch {
            guard analyticsRequestGeneration == request.generation else {
                return .init(loaded: false, failureMessage: nil)
            }
            if request.cacheGeneration == analyticsCacheGeneration { restoreRequestedSelection() }
            return failure(error, for: request)
        }
    }

    func refreshAnalytics(anchorDate: Date? = nil) async -> RefreshResult {
        guard let request = prepareRefresh(anchorDate: anchorDate) else {
            return .init(loaded: false, failureMessage: nil)
        }
        return await finishRefresh(request)
    }

    func invalidateForMutation() {
        analyticsRequestGeneration += 1
        advanceCacheGeneration()
    }

    func stopPrefetching() { prefetch.cancel() }

    func updatePrefetching(range: StudyTimeRange) {
        ensureContext()
        guard activeUserID != nil, let analytics,
              let anchor = context.date(analytics.anchorDate) else { return }
        let targets = viewport.targets(anchor: anchor, range: range,
                                       generatedAt: analytics.generatedAt, context: context)
        let needed = targets.filter { target in
            guard let entry = availableEntry(anchorDate: target.anchor, range: target.range) else { return true }
            return !isFresh(entry)
        }
        prefetch.update(needed) { [weak self] target in
            _ = await self?.prefetchAnalytics(anchorDate: target.anchor, range: target.range, speculative: true)
        }
    }

    private func prepareSelection(anchorDate: Date, range: StudyTimeRange?) -> RefreshRequest? {
        analyticsRequestGeneration += 1
        revalidationTask?.cancel()
        requestedAnalyticsAnchor = anchorDate
        requestedAnalyticsRange = range
        return requestContext(anchorDate: anchorDate, range: range)
    }

    private func restoreRequestedSelection() {
        requestedAnalyticsAnchor = analytics.flatMap { context.date($0.anchorDate) }
        requestedAnalyticsRange = requestedAnalyticsRange.flatMap { analytics?.range($0)?.key }
            ?? analytics?.ranges.first?.key ?? .week
    }

    private func shouldRetrySelection(_ request: RefreshRequest) -> Bool {
        !Task.isCancelled && activeUserID == request.userID && api.accessToken == request.authorizationToken
            && context == request.context && context.timeZone == timeZone()
            && analyticsRequestGeneration == request.generation
            && analyticsCacheGeneration != request.cacheGeneration
    }

    private func requestContext(anchorDate: Date, range: StudyTimeRange?) -> RefreshRequest? {
        guard let userID = activeUserID, !Task.isCancelled else { return nil }
        return .init(userID: userID, generation: analyticsRequestGeneration, anchorDate: anchorDate,
                     cacheGeneration: analyticsCacheGeneration, context: context,
                     range: range, authorizationToken: api.accessToken)
    }

    private func isCurrentContext(_ request: RefreshRequest) -> Bool {
        !Task.isCancelled && activeUserID == request.userID
            && analyticsCacheGeneration == request.cacheGeneration
            && context == request.context && context.timeZone == timeZone()
            && api.accessToken == request.authorizationToken
    }

    private func failure(_ error: Error, for request: RefreshRequest) -> RefreshResult {
        .init(loaded: false, failureMessage: isCurrentContext(request) ? error.localizedDescription : nil)
    }

    private func cache(_ value: StudyTimeAnalytics, for request: RefreshRequest) {
        periodCache.insert(value, requestedAnchor: request.context.anchor(request.anchorDate),
                           generation: request.cacheGeneration, receivedAt: now(),
                           requestedRanges: StudyTimeAnalyticsScope.ranges(for: request.range))
        persistSnapshot(analytics: value)
    }

    private func availableEntry(anchorDate: Date, range: StudyTimeRange?) -> StudyTimePeriodCache.Entry? {
        guard let entry = periodCache.entry(anchor: anchorDate, range: range, context: context) else { return nil }
        let age = now().timeIntervalSince(entry.receivedAt)
        return age >= 0 && age < StudyTimePeriodHistory.maximumAge ? entry : nil
    }

    private func isFresh(_ entry: StudyTimePeriodCache.Entry) -> Bool {
        StudyTimePeriodFreshness.isFresh(entry, generation: analyticsCacheGeneration, now: now(), context: context)
    }

    private func publish(_ value: StudyTimeAnalytics) {
        analytics = value
        let anchor = context.date(value.anchorDate)
        requestedAnalyticsAnchor = anchor.flatMap {
            context.calendar.isDate($0, inSameDayAs: now()) ? nil : $0
        }
    }

    private func revalidate(anchorDate: Date, range: StudyTimeRange?) {
        guard let request = requestContext(anchorDate: anchorDate, range: range) else { return }
        revalidationTask = Task {
            _ = await self.finishRefresh(request)
            if self.analyticsRequestGeneration == request.generation { self.revalidationTask = nil }
        }
    }

    private func fetchAnalytics(_ request: RefreshRequest) async throws -> StudyTimeAnalytics {
        guard isCurrentContext(request) else { throw CancellationError() }
        let anchor = request.context.anchor(request.anchorDate)
        let api = api
        let ranges = StudyTimeAnalyticsScope.ranges(for: request.range)
        let key = StudyTimeAnalyticsScope.key(anchor: anchor, ranges: ranges)
        return try await requests.value(for: key) {
            try Task.checkCancellation()
            guard api.accessToken == request.authorizationToken else { throw CancellationError() }
            return try await api.request(
                "/api/study/activity-analytics",
                query: [
                    URLQueryItem(name: "timezone", value: request.context.timeZone.identifier),
                    URLQueryItem(name: "weekStartsOn", value: String(request.context.weekStartsOn)),
                    URLQueryItem(name: "anchorDate", value: anchor),
                ] + StudyTimeAnalyticsScope.query(ranges),
                authorizationToken: request.authorizationToken, response: StudyTimeAnalytics.self
            )
        }
    }

    private func advanceCacheGeneration() {
        analyticsCacheGeneration += 1
        prefetch.cancel()
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
        guard context != current || contextToken != api.accessToken else { return }
        context = current
        contextToken = api.accessToken
        analyticsRequestGeneration += 1
        analytics = nil
        requestedAnalyticsAnchor = nil
        invalidateAnalyticsCache()
    }

    private func restoreSnapshot(userID: Int) {
        let timeZone = context.timeZone.identifier
        guard let snapshot = snapshotCache.load(userID: userID, timeZone: timeZone) else { return }
        let age = now().timeIntervalSince(snapshot.savedAt)
        guard age >= 0, age < 7 * 86_400 else { return }
        restoreAnalytics(snapshot, userID: userID)
        if let cachedRecap = snapshot.weeklyRecap,
           recapMatchesMostRecentCompletedWeek(cachedRecap, timeZone: timeZone)
        {
            weeklyRecap = cachedRecap
            weeklyRecapRefreshedAt = snapshot.weeklyRecapRefreshedAt ?? snapshot.savedAt
        }
    }

    private func restoreAnalytics(_ snapshot: StudyTimeSnapshot, userID: Int) {
        if let history = snapshot.periodHistory {
            for entry in history.restored(userID: userID, context: context, now: now()) {
                periodCache.insert(entry.value, requestedAnchor: entry.value.anchorDate,
                                   generation: analyticsCacheGeneration - 1, receivedAt: entry.receivedAt,
                                   requestedRanges: entry.requestedRanges)
            }
        } else if let value = snapshot.analytics,
                  value.timezone == context.timeZone.identifier, value.anchorDate == context.anchor(now()) {
            periodCache.insert(value, requestedAnchor: value.anchorDate,
                               generation: analyticsCacheGeneration - 1, receivedAt: snapshot.savedAt)
        }
        analytics = availableEntry(anchorDate: now(), range: .week)?.value
            ?? availableEntry(anchorDate: now(), range: nil)?.value
    }

    private func persistSnapshot(
        analytics value: StudyTimeAnalytics? = nil, timeZone: String? = nil
    ) {
        guard let userID = activeUserID else { return }
        let timeZone = timeZone ?? context.timeZone.identifier
        let value = value ?? analytics
        let history = timeZone == context.timeZone.identifier
            ? StudyTimePeriodHistory(userID: userID, context: context, snapshots: periodCache.snapshots) : nil
        snapshotCache.save(
            StudyTimeSnapshot(
                savedAt: now(),
                analytics: value?.timezone == timeZone ? value : nil,
                weeklyRecap: weeklyRecap,
                weeklyRecapRefreshedAt: weeklyRecapRefreshedAt,
                periodHistory: history
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
