#if DEBUG
import Foundation

/// Records scheduling gaps internally; heartbeat ticks never publish observable
/// state or invalidate SwiftUI. These are not measured display frame times.
@MainActor
final class TimeChartFixtureProbe {
    private struct Measurement: Codable {
        let elapsedMS: Double
        let mainActorMaxGapMS: Double
        let mainActorP95GapMS: Double
        let mainActorGapsOver50MS: Int
        let heartbeatSamples: Int
        let historySessionCount: Int
        let traffic: [String: Int]
    }

    private var task: Task<Void, Never>?
    private var gaps: [Double] = []
    private var previous = ContinuousClock.now
    private var started = ContinuousClock.now
    private var initialTraffic: [String: Int] = [:]

    func start() {
        task?.cancel()
        gaps = []
        started = .now
        previous = started
        initialTraffic = TimeChartFixtureProtocol.traffic()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return }
                self?.sample()
            }
        }
    }

    func finish() -> String {
        task?.cancel()
        task = nil
        sample()
        let sorted = gaps.sorted()
        let traffic = TimeChartFixtureProtocol.traffic()
        let delta = Dictionary(uniqueKeysWithValues: traffic.map { key, value in
            (key, value - initialTraffic[key, default: 0])
        })
        let result = Measurement(
            elapsedMS: milliseconds(started.duration(to: .now)),
            mainActorMaxGapMS: sorted.last ?? 0,
            mainActorP95GapMS: sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)],
            mainActorGapsOver50MS: gaps.filter { $0 > 50 }.count,
            heartbeatSamples: gaps.count,
            historySessionCount: TimeChartFixtureHistory.shared.events.count,
            traffic: delta
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    private func sample() {
        let now = ContinuousClock.now
        gaps.append(milliseconds(previous.duration(to: now)))
        previous = now
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
#endif
