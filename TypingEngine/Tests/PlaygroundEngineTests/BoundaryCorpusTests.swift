import Foundation
import XCTest
@testable import PlaygroundEngine

// Opt-in, uncached section adjustments across the same 24 ordinary fixtures.
// Each changed reading invalidates the preceding phrase's score cache.
final class BoundaryCorpusTests: XCTestCase {
  func testFreshBoundaryCorpus() throws {
    guard let path = ProcessInfo.processInfo.environment["BOUNDARY_CORPUS_REPORT"] else {
      throw XCTSkip("Set BOUNDARY_CORPUS_REPORT for the full timing/quality export")
    }
    let engine = try PlaygroundEngine()
    let fixtures = try JSONDecoder().decode([Fixture].self, from: PlaygroundEngine.fixtures())
    var samples: [Sample] = []
    for trial in 0..<3 {
      for fixture in fixtures {
        let ordinary = try engine.candidates(for: .init(reading: fixture.reading, expanded: false, boundaries: []))
        let length = try XCTUnwrap(ordinary.first?.sections.first?.reading.utf16.count)
        let cut = length > 1 ? length - 1 : min(2, fixture.reading.utf16.count - 1)
        samples.append(try measure(engine, reading: fixture.reading, cut: cut, trial: trial))
      }
    }
    try JSONEncoder().encode(samples).write(to: URL(fileURLWithPath: path))
  }

  private func measure(_ engine: PlaygroundEngine, reading: String, cut: Int, trial: Int) throws -> Sample {
    let start = ContinuousClock.now
    let candidates = try engine.candidates(for: .init(reading: reading, expanded: true, boundaries: [cut]))
    let duration = start.duration(to: .now).components
    XCTAssertFalse(candidates.isEmpty)
    XCTAssertLessThanOrEqual(candidates.count, 160)
    return Sample(reading: reading, cut: cut, trial: trial,
                  ms: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, candidates: candidates)
  }

  private struct Fixture: Decodable { let reading: String }
  private struct Sample: Encodable {
    let reading: String
    let cut: Int
    let trial: Int
    let ms: Double
    let candidates: [ConversionCandidate]
  }
}
