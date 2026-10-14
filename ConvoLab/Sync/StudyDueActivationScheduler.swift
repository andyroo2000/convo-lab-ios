import Foundation

@MainActor
protocol StudyDueActivationScheduling: AnyObject {
    var now: Date { get }

    func schedule(
        at deadline: Date,
        action: @escaping @MainActor @Sendable () -> Void
    )

    func cancel()
}

@MainActor
final class RunLoopStudyDueActivationScheduler: StudyDueActivationScheduling {
    private var timer: Timer?

    var now: Date { .now }

    func schedule(
        at deadline: Date,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        let timer = Timer(
            timeInterval: max(0, deadline.timeIntervalSince(now)),
            repeats: false
        ) { _ in
            Task { @MainActor in
                action()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
