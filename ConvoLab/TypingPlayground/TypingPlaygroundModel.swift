import Foundation
import Observation
import PlaygroundEngine

@MainActor @Observable
final class TypingPlaygroundModel {
  let engine = TypingEngineActor()
  var state = "loading"
  var error: String?
  var preloadMs = 0.0
  var preparationTimings: [String: Double] = [:]
  var benchmarking = false
  private(set) var activeConversions = 0
  var progress = 0
  var total = 0
  private var preparing = false
  private let boundaryCases = [("はしでたべました", 1), ("はしでたべました", 2), ("きょうはいいてんきです", 3), ("かみをきりました", 2)]
  var report: TypingBenchmarkReport?
  var reportURL: URL?
  var benchmarkTask: Task<Void, Never>?

  func prepare() async {
    guard state != "ready", !preparing else { return }
    preparing = true
    defer { preparing = false }
    state = "loading"
    error = nil
    do {
      preloadMs = try await engine.prepare()
      preparationTimings = await engine.preparationTimings()
      state = "ready"
    } catch {
      state = "error"
      self.error = error.localizedDescription
    }
  }

  func bridge(path: String, body: String?) async -> String {
    if path == "/api/v1/engine/retry" {
      if state == "error" {
        state = "loading"
        error = nil
        Task { await prepare() }
      }
      return bridgeStatus(state: state, error: error)
    }
    if path == "/api/v1/engine" { return bridgeStatus(state: state, error: error) }
    guard path == "/api/v1/convert", let body, state == "ready", !benchmarking
    else { return bridgeStatus(error: "The typing engine is busy or not ready.") }
    activeConversions += 1
    defer { activeConversions -= 1 }
    do {
      return try await engine.convert(body)
    } catch { return bridgeStatus(error: error.localizedDescription) }
  }

  func startBenchmark() {
    guard state == "ready", !benchmarking, activeConversions == 0 else { return }
    benchmarking = true
    progress = 0
    reportURL = nil
    report = TypingBenchmarkReport(preloadMs: preloadMs, preparationTimings: preparationTimings)
    benchmarkTask = Task { await runBenchmark() }
  }

  func cancelBenchmark() { benchmarkTask?.cancel() }

  private func runBenchmark() async {
    defer { benchmarking = false }
    do {
      try Task.checkCancellation()
      let fixtures = try JSONDecoder().decode(
        [TypingBenchmarkFixture].self, from: PlaygroundEngine.fixtures())
      total = fixtures.count * 3 + boundaryCases.count * 2
      for trial in 0..<3 {
        for fixture in fixtures {
          try await measure(fixture, trial: trial, boundaries: [])
        }
      }
      try await measureBoundaries(fixtures)
      report?.completed = true
    } catch {
      report?.failure =
        error is CancellationError ? "Cancelled; partial run" : error.localizedDescription
    }
    do { reportURL = try report?.save() } catch {
      self.error = "Could not save the benchmark report: \(error.localizedDescription)"
    }
  }

  private func measureBoundaries(_ fixtures: [TypingBenchmarkFixture]) async throws {
    for (reading, boundary) in boundaryCases {
      let fixture = fixtures.first { $0.reading == reading }
        ?? TypingBenchmarkFixture(reading: reading, expected: [], nativeTopChoice: nil)
      for trial in 0..<2 {
        try await measure(fixture, trial: trial, boundaries: [boundary])
      }
    }
  }

  private func measure(_ fixture: TypingBenchmarkFixture, trial: Int, boundaries: [Int])
    async throws
  {
    try Task.checkCancellation()
    let input: [String: Any] = [
      "reading": fixture.reading, "expanded": !boundaries.isEmpty, "boundaries": boundaries,
    ]
    let start = ContinuousClock.now
    let data = try JSONSerialization.data(withJSONObject: input)
    let json = try await engine.convert(String(decoding: data, as: UTF8.self))
    let result = try JSONDecoder().decode(TypingConversionResult.self, from: Data(json.utf8))
    report?.samples.append(
      TypingBenchmarkSample(
        phase: boundaries.isEmpty ? "ordinary" : "boundary", trial: trial,
        reading: fixture.reading, boundaries: boundaries,
        wallMs: TypingEngineActor.milliseconds(since: start), engineMs: result.engineMs,
        candidates: result.candidates.map(\.text), expected: fixture.expected,
        nativeTopChoice: fixture.nativeTopChoice,
        thermalState: String(describing: ProcessInfo.processInfo.thermalState),
        memoryFootprintBytes: TypingMemoryFootprint.current()
      ))
    progress += 1
  }
}

private struct TypingConversionResult: Decodable {
  struct Candidate: Decodable { let text: String }
  let engineMs: Double
  let candidates: [Candidate]
}

private struct TypingBridgeStatus: Encodable, Sendable {
  let state: String?
  let error: String?
}

private func bridgeStatus(state: String? = nil, error: String? = nil) -> String {
  let status = TypingBridgeStatus(state: state, error: error)
  guard let data = try? JSONEncoder().encode(status) else {
    return "{\"error\":\"Could not encode engine status\"}"
  }
  return String(decoding: data, as: UTF8.self)
}
