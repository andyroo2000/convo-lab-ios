import Foundation

@MainActor
final class ReadingPageResourceLoader {
    private var generation = 0
    private var task: Task<Void, Never>?

    // No actor-bound teardown; avoid the older Swift runtime's isolated-deinit
    // failure outside a task (swiftlang/swift issue #87316).
    nonisolated deinit {}

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    @discardableResult
    func load(
        fetch: @escaping () async throws -> Data,
        apply: @escaping (Data) async throws -> Void,
        report: @escaping (any Error) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let requestedGeneration = generation
        let request = Task {
            defer { if generation == requestedGeneration { task = nil } }
            do {
                try Task.checkCancellation()
                let bytes = try await fetch()
                try Task.checkCancellation()
                guard generation == requestedGeneration else { return }
                try await apply(bytes)
            } catch {
                guard generation == requestedGeneration, !Task.isCancelled,
                      !(error is CancellationError) else { return }
                report(error)
            }
        }
        task = request
        return request
    }
}
