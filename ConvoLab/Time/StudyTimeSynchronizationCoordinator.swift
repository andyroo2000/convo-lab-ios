import Foundation

@MainActor
final class StudyTimeSynchronizationCoordinator {
    typealias LoadedSessions = StudyTimeSessionMutationRepository.LoadedSessions

    struct PushOutcome {
        let context: Context?
        let loadedSessions: LoadedSessions?
        let failureMessage: String?
        let becameStale: Bool
        let shouldApply: Bool

        func joined() -> Self {
            Self(
                context: context,
                loadedSessions: loadedSessions,
                failureMessage: failureMessage,
                becameStale: becameStale,
                shouldApply: false
            )
        }
    }

    struct SynchronizationOutcome {
        let context: Context?
        let loadedSessions: LoadedSessions?
        let failureMessage: String?
        let becameStale: Bool
        let shouldApply: Bool

        func joined() -> Self {
            Self(
                context: context,
                loadedSessions: loadedSessions,
                failureMessage: failureMessage,
                becameStale: becameStale,
                shouldApply: false
            )
        }
    }

    struct Context {
        let userID: Int
        let activationID: UUID
        let mutationGeneration: Int
        let authorizationToken: String?
    }

    private let api: APIClient
    private let repository: StudyTimeSessionMutationRepository
    private let insights: StudyTimeInsightsController

    private var activeUserID: Int?
    private(set) var activationID: UUID?
    private var localMutationGeneration = 0
    private var synchronizationTask: Task<SynchronizationOutcome, Never>?
    private var synchronizationID: UUID?
    private var synchronizationContext: Context?
    private var pendingPushTask: Task<PushOutcome, Never>?
    private var pendingPushID: UUID?
    private var pendingPushContext: Context?
    private var pendingPushNeedsAnotherPass = false

    init(api: APIClient, repository: StudyTimeSessionMutationRepository, insights: StudyTimeInsightsController) {
        self.api = api
        self.repository = repository
        self.insights = insights
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        cancelPendingWork()
        localMutationGeneration += 1
        activationID = UUID()
        activeUserID = userID
    }

    func deactivate() {
        cancelPendingWork()
        localMutationGeneration += 1
        activationID = nil
        activeUserID = nil
    }

    func markLocalMutation() {
        localMutationGeneration += 1
        insights.invalidateForMutation()
    }

    func canApply(_ context: Context?) -> Bool { context.map(isCurrent) == true }

    func pushPending() async -> PushOutcome? {
        guard let context = currentContext() else { return nil }
        if let pendingPushTask, pendingPushContext.map(isActive) == true {
            pendingPushNeedsAnotherPass = true
            let outcome = await pendingPushTask.value
            return isActive(context) ? outcome.joined() : nil
        }
        pendingPushTask?.cancel()
        let pushID = UUID()
        let task = Task { [weak self] in
            guard let self else { return Self.stalePush() }
            let outcome = await self.drainPendingPushes(context: context)
            if self.pendingPushID == pushID {
                self.pendingPushTask = nil
                self.pendingPushID = nil
                self.pendingPushContext = nil
            }
            return outcome
        }
        pendingPushID = pushID
        pendingPushContext = context
        pendingPushTask = task
        return await task.value
    }

    func synchronize() async -> SynchronizationOutcome? {
        guard let context = currentContext() else { return nil }
        if let synchronizationTask, synchronizationContext.map(isActive) == true {
            let outcome = await synchronizationTask.value
            return isActive(context) ? outcome.joined() : nil
        }
        synchronizationTask?.cancel()
        let synchronizationID = UUID()
        let task = Task { [weak self] in
            guard let self else { return Self.staleSynchronization() }
            return await self.performSynchronization(context: context)
        }
        self.synchronizationID = synchronizationID
        synchronizationContext = context
        synchronizationTask = task
        let outcome = await task.value
        if self.synchronizationID == synchronizationID {
            synchronizationTask = nil
            self.synchronizationID = nil
            synchronizationContext = nil
        }
        return outcome
    }

    private func performSynchronization(context activation: Context) async -> SynchronizationOutcome {
        guard isActive(activation) else { return Self.staleSynchronization() }
        let pushOutcome = await pushPending()
        guard isActive(activation), let context = currentContext() else { return Self.staleSynchronization() }
        // The upload barrier owns the new analytics epoch. Reads started before
        // acknowledged writes cannot be reused as the post-upload refresh.
        let analyticsRequest = insights.prepareRefresh()
        async let analytics = refreshAnalytics(analyticsRequest)
        let history = await refreshHistory(context: context)
        let analyticsResult = await analytics
        guard isCurrent(context), !history.becameStale else { return Self.staleSynchronization() }
        return SynchronizationOutcome(
            context: context,
            loadedSessions: history.loadedSessions ?? pushOutcome?.loadedSessions,
            failureMessage: pushOutcome?.failureMessage ?? history.failureMessage ?? analyticsResult.failureMessage,
            becameStale: false,
            shouldApply: true
        )
    }

    private func refreshAnalytics(_ request: StudyTimeInsightsController.RefreshRequest?) async
        -> StudyTimeInsightsController.RefreshResult {
        guard let request else { return .init(loaded: false, failureMessage: nil) }
        return await insights.finishRefresh(request)
    }

    private func refreshHistory(context: Context) async -> SynchronizationOutcome {
        guard isCurrent(context) else { return Self.staleSynchronization() }
        let to = Date.now.addingTimeInterval(60)
        let from = to.addingTimeInterval(-93 * 86_400)
        do {
            let remote = try await api.request(
                "/api/study/activity-sessions",
                query: [URLQueryItem(name: "from", value: from.ISO8601Format()),
                        URLQueryItem(name: "to", value: to.ISO8601Format())],
                authorizationToken: context.authorizationToken,
                response: [StudyActivitySession].self
            )
            guard isCurrent(context) else { return Self.staleSynchronization() }
            let loaded = try await repository.mergeRemoteSessions(remote, userID: context.userID) { [weak self] in
                self?.isCurrent(context) == true
            }
            return .init(context: context, loadedSessions: loaded,
                         failureMessage: nil, becameStale: false, shouldApply: true)
        } catch is CancellationError {
            return Self.staleSynchronization()
        } catch {
            guard isCurrent(context) else { return Self.staleSynchronization() }
            return .init(context: context, loadedSessions: nil, failureMessage: error.localizedDescription,
                         becameStale: false, shouldApply: true)
        }
    }

    private func drainPendingPushes(context activation: Context) async -> PushOutcome {
        var latestOutcome = Self.stalePush()
        repeat {
            guard isActive(activation), let context = currentContext() else { return Self.stalePush() }
            pendingPushNeedsAnotherPass = false
            latestOutcome = await performPushPending(context: context)
            if isActive(activation), !isCurrent(context) { pendingPushNeedsAnotherPass = true }
        } while isActive(activation) && pendingPushNeedsAnotherPass
        return latestOutcome
    }

    private func performPushPending(context: Context) async -> PushOutcome {
        let result = await repository.pushPending(
            userID: context.userID, mutationGeneration: context.mutationGeneration,
            authorizationToken: context.authorizationToken
        ) { [weak self] _, _ in self?.isCurrent(context) == true }
        guard !result.becameStale, isCurrent(context) else { return Self.stalePush() }
        // Upload acknowledgements only change sync metadata. The store already
        // holds the local session values, and history supplies the next projection.
        return PushOutcome(context: context, loadedSessions: nil,
                           failureMessage: result.failures.first, becameStale: false, shouldApply: true)
    }

    private func currentContext() -> Context? {
        guard let userID = activeUserID, let activationID, !Task.isCancelled else { return nil }
        return Context(userID: userID, activationID: activationID, mutationGeneration: localMutationGeneration,
                       authorizationToken: api.accessToken)
    }

    private func isActive(_ context: Context) -> Bool {
        !Task.isCancelled && activeUserID == context.userID && activationID == context.activationID
            && api.accessToken == context.authorizationToken
    }

    private func isCurrent(_ context: Context) -> Bool {
        isActive(context) && localMutationGeneration == context.mutationGeneration
    }

    private func cancelPendingWork() {
        synchronizationTask?.cancel()
        synchronizationTask = nil
        synchronizationID = nil
        synchronizationContext = nil
        pendingPushTask?.cancel()
        pendingPushTask = nil
        pendingPushID = nil
        pendingPushContext = nil
        pendingPushNeedsAnotherPass = false
    }

    private static func stalePush() -> PushOutcome {
        .init(context: nil, loadedSessions: nil, failureMessage: nil, becameStale: true, shouldApply: true)
    }

    private static func staleSynchronization() -> SynchronizationOutcome {
        .init(context: nil, loadedSessions: nil, failureMessage: nil, becameStale: true, shouldApply: true)
    }
}
