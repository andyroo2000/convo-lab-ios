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
}
