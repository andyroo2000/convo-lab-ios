import Foundation
import XCTest
@testable import PlaygroundEngine
@testable import KanaKanjiConverterModule

final class SharedPromptTests: XCTestCase {
  private func withScorer(_ check: (ZenzContext, BoundaryBatchScorer) throws -> Void) throws {
    let engine = try PlaygroundEngine()
    let context = try XCTUnwrap(engine.converter.getModel(modelURL: engine.modelURL)?.zenzContext)
    guard let scorer = try context.makeBoundaryBatchScorer() else {
      throw XCTSkip("Shared prompt KV requires Metal; CPU keeps upstream scoring")
    }
    try check(context, scorer)
  }

  func testEmptyContinuationAndMixedSuffixesAcrossSequenceLimit() throws {
    try withScorer { context, scorer in
      let prompt = "\u{EE00}ハシ\u{EE01}"
      let texts = (0..<35).map { ["", "箸", "橋", "端"][$0 % 4] }
      let scores = try context.boundaryScores(texts: texts, prompt: prompt, batch: scorer)
      let expected = texts.map { context.evaluate(text: prompt + $0, ignorePrompt: prompt) }
      for (actual, reference) in zip(scores, expected) {
        XCTAssertEqual(actual, reference, accuracy: 0.01)
      }
      XCTAssertEqual(scores.count, 35)
      let empty = try context.boundaryScores(texts: Array(repeating: "", count: 35), prompt: prompt, batch: scorer)
      XCTAssertEqual(empty.count, 35)
      for score in empty { XCTAssertEqual(score, expected[0], accuracy: 0.01) }
      XCTAssertEqual(try context.boundaryScores(texts: [], prompt: prompt, batch: scorer), [])
    }
  }

  func testRejectsInvalidSharedTokensAndRecoversNextRequest() throws {
    try withScorer { context, scorer in
      // Validation must finish before mutating KV state or indexing sentences.
      for start in [-1, 0, 2, 3] {
        XCTAssertThrowsError(try scorer.evaluate([[2, 3]], promptCount: start, vocabulary: 10))
      }
      XCTAssertThrowsError(try scorer.evaluate([[2, 4, 3], [2]], promptCount: 2, vocabulary: 10))
      XCTAssertThrowsError(try scorer.evaluate([[2, 4, 3], [2, 5, 3]], promptCount: 2, vocabulary: 10))
      let prompt = "\u{EE00}ハシ\u{EE01}"
      let texts = ["箸", "橋"]
      let first = try context.boundaryScores(texts: texts, prompt: prompt, batch: scorer)
      _ = try context.boundaryScores(texts: ["雨"], prompt: "\u{EE00}アメ\u{EE01}", batch: scorer)
      let again = try context.boundaryScores(texts: texts, prompt: prompt, batch: scorer)
      XCTAssertEqual(first, again, "A changed reading must not leave shared KV state behind")
    }
  }
}
