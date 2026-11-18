import Foundation
import XCTest
@testable import PlaygroundEngine

final class TypingLatencyTests: XCTestCase {
  func testFullPhraseAndBoundaryBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["TYPING_LATENCY_REPORT"] else {
      throw XCTSkip("Opt-in timing run; set TYPING_LATENCY_REPORT to an output path")
    }
    let start = ContinuousClock.now
    let engine = try PlaygroundEngine()
    let preload = milliseconds(since: start)
    let fixtures = try JSONDecoder().decode([Fixture].self, from: PlaygroundEngine.fixtures())
    let samples = try ordinarySamples(engine, fixtures: fixtures) + boundarySamples(engine)
    let report: [String: Any] = ["preloadMs": preload, "preparationTimings": engine.preparationTimings, "samples": samples]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
  }

  private func ordinarySamples(_ engine: PlaygroundEngine, fixtures: [Fixture]) throws -> [[String: Any]] {
    var samples: [[String: Any]] = []
    for trial in 0..<3 {
      for fixture in fixtures {
        samples.append(try measure(engine, reading: fixture.reading, cuts: [], trial: trial))
      }
    }
    return samples
  }

  private func boundarySamples(_ engine: PlaygroundEngine) throws -> [[String: Any]] {
    var samples: [[String: Any]] = []
    for (reading, cut) in [("はしでたべました", 1), ("はしでたべました", 2),
                           ("きょうはいいてんきです", 3), ("かみをきりました", 2)] {
      for trial in 0..<2 {
        samples.append(try measure(engine, reading: reading, cuts: [cut], trial: trial))
      }
    }
    return samples
  }

  private func measure(_ engine: PlaygroundEngine, reading: String, cuts: [Int], trial: Int) throws -> [String: Any] {
    let input: [String: Any] = ["reading": reading, "boundaries": cuts, "expanded": !cuts.isEmpty]
    let json = try JSONSerialization.data(withJSONObject: input)
    let start = ContinuousClock.now
    let output = try engine.convert(String(decoding: json, as: UTF8.self))
    var result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    result["wallMs"] = milliseconds(since: start)
    result["reading"] = reading
    result["boundaries"] = cuts
    result["trial"] = trial
    let candidates = try XCTUnwrap(result["candidates"] as? [[String: Any]])
    XCTAssertFalse(candidates.isEmpty)
    if cuts.isEmpty { XCTAssertLessThanOrEqual(candidates.count, 10) }
    else { XCTAssertEqual(candidates.count, 160) }
    return result
  }

  private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
  }

  private struct Fixture: Decodable { let reading: String }
}
