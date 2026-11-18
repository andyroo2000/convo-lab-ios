import Foundation
import XCTest
@testable import PlaygroundEngine
@testable import KanaKanjiConverterModule

final class SessionResetTests: XCTestCase {
  func testRetainingGPUContextMatchesRecreatingItForEveryFixture() throws {
    let engine = try PlaygroundEngine()
    let context = try XCTUnwrap(engine.converter.getModel(modelURL: engine.modelURL)?.zenzContext)
    let fixtures = try JSONDecoder().decode([Fixture].self, from: PlaygroundEngine.fixtures())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for fixture in fixtures {
      let input = ConversionInput(reading: fixture.reading, expanded: false, boundaries: [])
      let retained = try encoder.encode(engine.candidates(for: input))
      // Upstream behavior destroyed and rebuilt the context on every phrase.
      try context.reset_context()
      let recreated = try encoder.encode(engine.candidates(for: input))
      XCTAssertEqual(retained, recreated, "Candidates or section boundaries changed for \(fixture.reading)")
    }
  }

  private struct Fixture: Decodable { let reading: String }

  func testFirstBoundaryReturnsTheFullListAndPreparesOnlyOnce() throws {
    let engine = try PlaygroundEngine()
    XCTAssertNil(engine.preparationTimings["boundaryWarmupMs"])
    let input = ConversionInput(reading: "はしでたべました", expanded: true, boundaries: [2])
    let first = try engine.candidates(for: input)
    XCTAssertEqual(first.count, 160)
    let warmup = try XCTUnwrap(engine.preparationTimings["boundaryWarmupMs"])
    let repeated = try engine.candidates(for: input)
    XCTAssertEqual(repeated.map(\.text), first.map(\.text))
    XCTAssertEqual(engine.preparationTimings["boundaryWarmupMs"], warmup)
  }
}
