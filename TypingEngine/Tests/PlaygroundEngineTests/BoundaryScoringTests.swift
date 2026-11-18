import Foundation
import XCTest
@testable import PlaygroundEngine
@testable import KanaKanjiConverterModule

final class BoundaryScoringTests: XCTestCase {
  func testEveryCandidateMatchesUpstreamFullSentenceScores() throws {
    let engine = try PlaygroundEngine()
    let context = try XCTUnwrap(engine.converter.getModel(modelURL: engine.modelURL)?.zenzContext)
    guard let batch = try context.makeBoundaryBatchScorer() else {
      throw XCTSkip("Metal batching parity requires a GPU build; CPU uses upstream scoring unchanged")
    }
    for (reading, cut) in [("はしでたべました", 1), ("はしでたべました", 2),
                           ("きょうはいいてんきです", 3), ("かみをきりました", 2)] {
      let input = ConversionInput(reading: reading, expanded: true, boundaries: [cut])
      let candidates = try engine.candidates(for: input)
      XCTAssertEqual(candidates.count, 160)
      let texts = candidates.map { $0.text.replacingOccurrences(of: " ", with: "\u{3000}") }
      let kana = try XCTUnwrap(reading.applyingTransform(.hiraganaToKatakana, reverse: false))
      let prompt = "\u{EE00}\(kana)\u{EE01}"
      let scores = try context.boundaryScores(texts: texts, prompt: prompt, batch: batch)
      let reference = texts.map { context.evaluate(text: prompt + $0, ignorePrompt: prompt) }
      for (actual, expected) in zip(scores, reference) {
        XCTAssertEqual(actual, expected, accuracy: 0.01, "Full-vocabulary score changed")
      }
      XCTAssertEqual(bestIndex(scores), bestIndex(reference), "Best candidate changed for \(reading)")
      // Reusing scores and sharing model ownership must not alter the complete
      // result or leak a previous boundary into ordinary live conversion.
      let repeated = try engine.candidates(for: input)
      XCTAssertEqual(repeated.map(\.text), candidates.map(\.text))
      let ordinary = try engine.candidates(for: .init(reading: reading, expanded: false, boundaries: []))
      let again = try engine.candidates(for: .init(reading: reading, expanded: false, boundaries: []))
      XCTAssertEqual(ordinary.map(\.text), again.map(\.text))
    }
  }

  func testCacheIsReadingSpecific() {
    var cache = BoundaryScoreCache()
    cache.begin(reading: "はし")
    cache.store(-1, for: "箸")
    XCTAssertEqual(cache.score(for: "箸"), -1)
    cache.begin(reading: "はし")
    XCTAssertEqual(cache.score(for: "箸"), -1)
    cache.begin(reading: "おはし")
    XCTAssertNil(cache.score(for: "箸"))
  }

  func testCacheEvictsAtItsBound() {
    var cache = BoundaryScoreCache()
    cache.begin(reading: "はし")
    for index in 0...512 { cache.store(Float(index), for: String(index)) }
    XCTAssertNil(cache.score(for: "0"))
    XCTAssertEqual(cache.score(for: "512"), 512)
  }

  func testLongCandidatesKeepTheirFullContextAcrossBatchSplits() throws {
    let engine = try PlaygroundEngine()
    let context = try XCTUnwrap(engine.converter.getModel(modelURL: engine.modelURL)?.zenzContext)
    guard let batch = try context.makeBoundaryBatchScorer() else {
      throw XCTSkip("Batch splitting requires a GPU build; CPU evaluates sentences individually")
    }
    let reading = String(repeating: "キョウハイイテンキデス", count: 8)
    let prompt = "\u{EE00}\(reading)\u{EE01}"
    let texts = (0..<18).map { index in
      String(repeating: "今日はいい天気です", count: 7) + ["今日はいい天気です", "今日は良い天気です"][index % 2]
    }
    let scores = try context.boundaryScores(texts: texts, prompt: prompt, batch: batch)
    XCTAssertEqual(scores.count, texts.count)
    for (index, text) in texts.enumerated() {
      let reference = context.evaluate(text: prompt + text, ignorePrompt: prompt)
      XCTAssertEqual(scores[index], reference, accuracy: 0.01)
    }
  }

  private func bestIndex(_ scores: [Float]) -> Int? {
    scores.indices.max { scores[$0] < scores[$1] }
  }

  func testOversizedSentenceFailsWithoutTruncationOrUnsafeScalarFallback() throws {
    let engine = try PlaygroundEngine()
    let context = try XCTUnwrap(engine.converter.getModel(modelURL: engine.modelURL)?.zenzContext)
    guard let batch = try context.makeBoundaryBatchScorer() else {
      throw XCTSkip("This guard protects Metal batching; CPU retains the upstream path")
    }
    // Upstream also has a 512-token context and batch. Its scalar path cannot
    // safely handle this input either, so never use it as an oversize fallback.
    let text = String(repeating: "あ", count: 1024)
    XCTAssertThrowsError(try context.boundaryScores(texts: [text], prompt: "\u{EE00}ア\u{EE01}", batch: batch))
  }
}
