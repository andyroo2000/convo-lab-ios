import Foundation

/// A scheduling-gap proxy, not frame timing. Sampling never publishes SwiftUI state.
@MainActor
final class StudyTimeStartupProbe {
    private let started = ContinuousClock.now
    private var previous = ContinuousClock.now
    private var gaps: [Double] = []
    private var firstVisibleMS: Double?
    private var firstFreshMS: Double?
    private var task: Task<Void, Never>?

    func start(state: @escaping @MainActor () -> (visible: Bool, fresh: Bool)) {
        sample(state())
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                self?.sample(state())
            }
        }
    }

    func finish(visible: Bool, fresh: Bool) -> StudyTimeStartupTiming {
        task?.cancel()
        task = nil
        sample((visible, fresh))
        let sorted = gaps.sorted()
        return .init(fullSyncMS: Self.ms(started.duration(to: .now)),
                     firstVisibleMS: firstVisibleMS, firstFreshMS: firstFreshMS,
                     maxMainActorGapMS: sorted.last ?? 0,
                     p95MainActorGapMS: sorted[Int(Double(sorted.count - 1) * 0.95)],
                     gapsOver50MS: gaps.filter { $0 > 50 }.count, samples: gaps.count)
    }

    private func sample(_ state: (visible: Bool, fresh: Bool)) {
        let now = ContinuousClock.now
        gaps.append(Self.ms(previous.duration(to: now)))
        previous = now
        let elapsed = Self.ms(started.duration(to: now))
        if state.visible, firstVisibleMS == nil { firstVisibleMS = elapsed }
        if state.fresh, firstFreshMS == nil { firstFreshMS = elapsed }
    }

    nonisolated static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

nonisolated struct StudyTimeStartupTiming: Codable {
    let fullSyncMS: Double
    let firstVisibleMS: Double?
    let firstFreshMS: Double?
    let maxMainActorGapMS: Double
    let p95MainActorGapMS: Double
    let gapsOver50MS: Int
    let samples: Int
}

nonisolated struct StudyTimeStartupRequest: Codable {
    let path: String
    let query: String
    let startedMS: Double
    let requestBytes: Int
    var endedMS: Double?
    var responseBytes = 0
    var cancelled = false
}

nonisolated struct StudyTimeStartupTraffic: Codable {
    var requests: [StudyTimeStartupRequest] = []
    var peakInFlight = 0
    var inFlight = 0
    var uploadedSessions = 0
}

nonisolated struct StudyTimeStartupMeasurement: Codable {
    let scenario: String
    let iteration: Int
    let historyCount: Int
    let pendingCount: Int
    let delaysMS: [String: Int]
    let activationMS: Double
    let timing: StudyTimeStartupTiming
    let traffic: StudyTimeStartupTraffic
    let persistedSessions: Int
    let remainingPending: Int
}
