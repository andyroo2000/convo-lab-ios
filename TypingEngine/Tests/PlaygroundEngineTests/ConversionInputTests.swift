import XCTest

@testable import PlaygroundEngine

final class ConversionInputTests: XCTestCase {
  func testPinnedModelLoadsAndConvertsWithoutFallback() throws {
    let engine = try PlaygroundEngine()
    let output = try engine.convert("{\"reading\":\"はしでたべました\"}")
    let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
    let candidates = result?["candidates"] as? [[String: Any]]
    XCTAssertEqual(candidates?.first?["text"] as? String, "箸で食べました")
  }

  func testRejectsInvalidReadingAndUTF16Boundaries() throws {
    for json in [
      "{\"reading\":\"\"}", "{\"reading\":\"あ\\nい\"}", "{\"reading\":\"😀あ\",\"boundaries\":[1]}",
      "{\"reading\":\"あいう\",\"boundaries\":[2,1]}",
    ] {
      let input = try JSONDecoder().decode(ConversionInput.self, from: Data(json.utf8))
      XCTAssertThrowsError(try input.validate())
    }
    let valid = try JSONDecoder().decode(
      ConversionInput.self, from: Data("{\"reading\":\"😀あ\",\"boundaries\":[2]}".utf8))
    XCTAssertNoThrow(try valid.validate())
  }
}
