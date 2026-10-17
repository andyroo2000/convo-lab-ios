import Foundation

/// Measures main-actor scheduling gaps, not rendering frame times. Run the same
/// workload/device/build configuration before and after a change for comparison.
@MainActor
final class SyncPerformanceProbe {
    private let startedAt = ContinuousClock.now
    private var previousPulse = ContinuousClock.now
    private var gaps: [Double] = []
    private var firstSessionVisibleMS: Double?
    private var task: Task<Void, Never>?

    func start(sessionIsVisible: @escaping @MainActor () -> Bool) {
        previousPulse = .now
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                sample(sessionIsVisible: sessionIsVisible())
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return }
            }
        }
    }

    func finish(sessionIsVisible: Bool) -> SyncPerformanceTiming {
        task?.cancel()
        task = nil
        sample(sessionIsVisible: sessionIsVisible)
        let sorted = gaps.sorted()
        return SyncPerformanceTiming(
            elapsedMS: Self.milliseconds(startedAt.duration(to: .now)),
            firstSessionVisibleMS: firstSessionVisibleMS,
            mainActorMaxGapMS: sorted.last ?? 0,
            mainActorP95GapMS: sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
            mainActorGapsOver50MS: gaps.filter { $0 > 50 }.count,
            heartbeatSamples: gaps.count
        )
    }

    private func sample(sessionIsVisible: Bool) {
        let now = ContinuousClock.now
        gaps.append(Self.milliseconds(previousPulse.duration(to: now)))
        previousPulse = now
        if sessionIsVisible, firstSessionVisibleMS == nil {
            firstSessionVisibleMS = Self.milliseconds(startedAt.duration(to: now))
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

nonisolated struct SyncPerformanceTiming: Codable {
    let elapsedMS: Double
    let firstSessionVisibleMS: Double?
    let mainActorMaxGapMS: Double
    let mainActorP95GapMS: Double
    let mainActorGapsOver50MS: Int
    let heartbeatSamples: Int
}

nonisolated struct SyncPerformanceTraffic: Codable {
    var requestsByPath: [String: Int] = [:]
    var responseBytes = 0
    var mediaItems = 0
    var mediaBytes = 0
}

nonisolated struct SyncPerformanceMeasurement: Codable {
    let phase: String
    let iteration: Int
    let cardCount: Int
    let activeCardCount: Int
    let reserveCardCount: Int
    let mediaBytesPerItem: Int
    let simulatedRequestLatencyMS: Int
    let activationMS: Double?
    let timing: SyncPerformanceTiming
    let traffic: SyncPerformanceTraffic
    let persistedCardCount: Int
    let cachedMediaCount: Int
    let preparedCardCount: Int
    let checkpoint: Int64
}
