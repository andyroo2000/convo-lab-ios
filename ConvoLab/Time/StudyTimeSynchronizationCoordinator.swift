import Foundation

@MainActor
final class StudyTimeSynchronizationCoordinator {
    typealias LoadedSessions = StudyTimeSessionMutationRepository.LoadedSessions

    struct PushOutcome {
        let loadedSessions: LoadedSessions?
        let failureMessage: String?
        let becameStale: Bool
    }

    struct SynchronizationOutcome {
        let loadedSessions: LoadedSessions?
        let failureMessage: String?
        let becameStale: Bool
    }

    private struct Context: Equatable {
        let userID: Int
        let mutationGeneration: Int
    }

    private let api: APIClient
    private let repository: StudyTimeSessionMutationRepository
    private let insights: StudyTimeInsightsController

    private var activeUserID: Int?
    private var localMutationGeneration = 0
    private var synchronizationTask: Task<SynchronizationOutcome, Never>?
    private var synchronizingUserID: Int?
    private var pendingPushTask: Task<PushOutcome, Never>?
    private var pendingPushID: UUID?
    private var pendingPushNeedsAnotherPass = false

    init(
        api: APIClient,
        repository: StudyTimeSessionMutationRepository,
        insights: StudyTimeInsightsController
    ) {
        self.api = api
        self.repository = repository
        self.insights = insights
    }

    func activate(userID: Int) {
        guard activeUserID != userID else { return }
        localMutationGeneration += 1
        activeUserID = userID
    }

    func deactivate() {
        localMutationGeneration += 1
        activeUserID = nil
    }

    func markLocalMutation() {
        localMutationGeneration += 1
    }

    func isCurrent(userID: Int) -> Bool {
        activeUserID == userID
    }

    func pushPending() async -> PushOutcome? {
        if let pendingPushTask {
            pendingPushNeedsAnotherPass = true
            return await pendingPushTask.value
        }
        guard activeUserID != nil else { return nil }
        let pushID = UUID()
        let task = Task { [weak self] in
            guard let self else {
                return PushOutcome(
                    loadedSessions: nil,
                    failureMessage: nil,
                    becameStale: true
                )
            }
            let outcome = await self.drainPendingPushes()
            if self.pendingPushID == pushID {
                self.pendingPushTask = nil
                self.pendingPushID = nil
            }
            return outcome
        }
        pendingPushID = pushID
        pendingPushTask = task
        return await task.value
    }

    func synchronize() async -> SynchronizationOutcome? {
        guard let requestedUserID = activeUserID else { return nil }
        if let synchronizationTask {
            let inFlightUserID = synchronizingUserID
            let outcome = await synchronizationTask.value
            guard activeUserID == requestedUserID else { return nil }
            if inFlightUserID == requestedUserID { return outcome }
        }
        guard activeUserID == requestedUserID else { return nil }
        let task = Task { [weak self] in
            guard let self else {
                return SynchronizationOutcome(
                    loadedSessions: nil,
                    failureMessage: nil,
                    becameStale: true
                )
            }
            return await self.performSynchronization(userID: requestedUserID)
        }
        synchronizationTask = task
        synchronizingUserID = requestedUserID
        let outcome = await task.value
        if synchronizingUserID == requestedUserID {
            synchronizationTask = nil
            synchronizingUserID = nil
        }
        return outcome
    }

    private func performSynchronization(userID: Int) async -> SynchronizationOutcome {
        let analyticsRequest = insights.prepareRefresh()
        let pushOutcome = await pushPending()
        var loadedSessions = pushOutcome?.loadedSessions
        var failures = pushOutcome?.failureMessage.map { [$0] } ?? []
        let context = Context(userID: userID, mutationGeneration: localMutationGeneration)
        let to = Date.now.addingTimeInterval(60)
        let from = to.addingTimeInterval(-93 * 86_400)
        do {
            let remote = try await api.request(
                "/api/study/activity-sessions",
                query: [
                    URLQueryItem(name: "from", value: from.ISO8601Format()),
                    URLQueryItem(name: "to", value: to.ISO8601Format()),
                ],
                response: [StudyActivitySession].self
            )
            if isCurrent(context) {
                _ = try repository.mergeRemoteSessions(remote, userID: userID)
                loadedSessions = repository.loadLocalSessions(userID: userID)
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        if let analyticsRequest {
            let analyticsResult = await insights.finishRefresh(analyticsRequest)
            if let failure = analyticsResult.failureMessage {
                failures.append(failure)
            }
        }
        guard isCurrent(context) else {
            return SynchronizationOutcome(
                loadedSessions: nil,
                failureMessage: nil,
                becameStale: true
            )
        }
        return SynchronizationOutcome(
            loadedSessions: loadedSessions,
            failureMessage: failures.first,
            becameStale: false
        )
    }

    private func drainPendingPushes() async -> PushOutcome {
        var latestOutcome = PushOutcome(
            loadedSessions: nil,
            failureMessage: nil,
            becameStale: false
        )
        repeat {
            pendingPushNeedsAnotherPass = false
            guard let userID = activeUserID else {
                return PushOutcome(
                    loadedSessions: nil,
                    failureMessage: nil,
                    becameStale: true
                )
            }
            let context = Context(
                userID: userID,
                mutationGeneration: localMutationGeneration
            )
            latestOutcome = await performPushPending(context: context)
            if activeUserID != nil, !isCurrent(context) {
                pendingPushNeedsAnotherPass = true
            }
        } while pendingPushNeedsAnotherPass
        return latestOutcome
    }

    private func performPushPending(context: Context) async -> PushOutcome {
        let result = await repository.pushPending(
            userID: context.userID,
            mutationGeneration: context.mutationGeneration
        ) { [weak self] userID, generation in
            self?.isCurrent(
                Context(userID: userID, mutationGeneration: generation)
            ) == true
        }
        guard !result.becameStale, isCurrent(context) else {
            return PushOutcome(
                loadedSessions: nil,
                failureMessage: nil,
                becameStale: true
            )
        }
        return PushOutcome(
            loadedSessions: repository.loadLocalSessions(userID: context.userID),
            failureMessage: result.failures.first,
            becameStale: false
        )
    }

    private func isCurrent(_ context: Context) -> Bool {
        activeUserID == context.userID
            && localMutationGeneration == context.mutationGeneration
    }
}
