import Foundation

/// Confirmation and reset share one order, including while an operation awaits the engine.
@MainActor
final class JournalLearningQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, Error> {
        let previous = tail
        let next = Task {
            await previous?.value
            try await operation()
        }
        tail = Task { _ = try? await next.value }
        return next
    }
}
