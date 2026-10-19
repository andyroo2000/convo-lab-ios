import Foundation

/// Owns one speculative consumer; foreground consumers retain their own transport ownership.
@MainActor
final class StudyTimeAnalyticsPrefetch {
    struct Target: Equatable {
        let anchor: Date
        let range: StudyTimeRange
    }

    private struct Running {
        let id: UUID
        let target: Target
        let task: Task<Void, Never>
    }

    private var wanted: [Target] = []
    private var running: Running?
    private var operation: (@MainActor (Target) async -> Void)?
    private var foregroundConsumers = 0

    nonisolated deinit {}

    func update(_ targets: [Target], operation: @escaping @MainActor (Target) async -> Void) {
        wanted = Array(targets.prefix(3))
        self.operation = operation
        if let running, !wanted.contains(running.target) {
            running.task.cancel()
            self.running = nil
        }
        startNext()
    }

    func cancel() {
        running?.task.cancel()
        running = nil
        wanted = []
        operation = nil
    }

    func beginForeground() { foregroundConsumers += 1 }

    func endForeground() {
        foregroundConsumers -= 1
        startNext()
    }

    private func startNext() {
        guard foregroundConsumers == 0, running == nil,
              let target = wanted.first, let operation else { return }
        let id = UUID()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation(target)
            self?.finished(id: id, target: target)
        }
        running = Running(id: id, target: target, task: task)
    }

    private func finished(id: UUID, target: Target) {
        guard running?.id == id else { return }
        running = nil
        wanted.removeAll { $0 == target }
        startNext()
    }
}

struct StudyTimeAnalyticsViewport {
    private var previous: StudyTimeAnalyticsPrefetch.Target?
    private var direction = -1

    mutating func targets(
        anchor: Date, range: StudyTimeRange, generatedAt: Date, context: StudyTimeAnalyticsCalendar
    ) -> [StudyTimeAnalyticsPrefetch.Target] {
        if let previous, previous.range == range, previous.anchor != anchor {
            direction = anchor < previous.anchor ? -1 : 1
        } else if previous?.range != range {
            direction = -1
        }
        previous = .init(anchor: anchor, range: range)
        return [direction, direction * 2, -direction].compactMap { amount in
            guard let shifted = context.shifted(anchor, range: range, by: amount),
                  let bounds = context.bounds(range, anchor: shifted), bounds.start <= generatedAt
            else { return nil }
            return .init(anchor: shifted, range: range)
        }
    }
}
