import Foundation

/// Owns app-wide refreshes so view and scene callbacks share the same work.
@MainActor
final class AppSyncLifecycle {
    struct Account: Equatable {
        let userID: Int
        let credential: String?
    }

    enum Refresh: Equatable {
        case authenticated(Account?)
        case foreground(Account)
        case studySurface(Account)

        func satisfies(_ requested: Refresh) -> Bool {
            if self == requested { return true }
            guard case let .authenticated(account) = self else { return false }
            switch requested {
            case let .foreground(requestedAccount), let .studySurface(requestedAccount):
                return account == requestedAccount
            case .authenticated:
                return false
            }
        }
    }

    private struct RunningRefresh {
        let id: UUID
        let kind: Refresh
        let task: Task<Void, Never>
    }

    private(set) var hasStarted = false
    private var startupTask: Task<Void, Never>?
    private var runningRefresh: RunningRefresh?

    func start(_ operation: @escaping @MainActor () async -> Void) async {
        guard !hasStarted else { return }
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task {
            if let runningRefresh = self.runningRefresh { await runningRefresh.task.value }
            await operation()
            self.hasStarted = true
            self.startupTask = nil
        }
        startupTask = task
        await task.value
    }

    func refresh(
        _ kind: Refresh,
        operation: @escaping @MainActor () async -> Void
    ) async {
        if let startupTask { await startupTask.value }
        while let runningRefresh {
            await runningRefresh.task.value
            if runningRefresh.kind.satisfies(kind) { return }
        }
        // The lifecycle owns this task. Cancelling a disappearing view must not
        // cancel another caller's authentication or durable outbox upload.
        let id = UUID()
        let task = Task {
            await operation()
            if self.runningRefresh?.id == id { self.runningRefresh = nil }
        }
        runningRefresh = RunningRefresh(id: id, kind: kind, task: task)
        await task.value
    }
}
