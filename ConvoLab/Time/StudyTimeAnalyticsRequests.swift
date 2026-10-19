import Foundation

/// A disappearing prefetch consumer must not cancel a request another consumer
/// is awaiting. The last consumer or a context reset owns transport cancellation.
@MainActor
final class StudyTimeAnalyticsRequests {
    private struct Pending {
        let id: UUID
        let task: Task<StudyTimeAnalytics, Error>
        var consumers: Set<UUID>
    }

    private var pending: [String: Pending] = [:]

    // No actor-bound teardown; same iOS 26.2 isolated-deinit workaround as the caches.
    nonisolated deinit {}

    func cancelAll() {
        for request in pending.values { request.task.cancel() }
        pending.removeAll()
    }

    func value(
        for key: String,
        operation: @escaping @MainActor () async throws -> StudyTimeAnalytics
    ) async throws -> StudyTimeAnalytics {
        try Task.checkCancellation()
        let consumer = UUID()
        let request = join(key: key, consumer: consumer, operation: operation)
        defer { release(key: key, requestID: request.id, consumer: consumer) }
        return try await withTaskCancellationHandler {
            let value = try await request.task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { @MainActor in
                self.release(key: key, requestID: request.id, consumer: consumer)
            }
        }
    }

    private func join(
        key: String, consumer: UUID,
        operation: @escaping @MainActor () async throws -> StudyTimeAnalytics
    ) -> Pending {
        if var request = pending[key] {
            request.consumers.insert(consumer)
            pending[key] = request
            return request
        }
        let request = Pending(id: UUID(), task: Task { try await operation() }, consumers: [consumer])
        pending[key] = request
        return request
    }

    private func release(key: String, requestID: UUID, consumer: UUID) {
        guard var request = pending[key], request.id == requestID else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            request.task.cancel()
            pending[key] = nil
        } else {
            pending[key] = request
        }
    }
}
