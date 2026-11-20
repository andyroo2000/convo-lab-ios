import Foundation
import Testing
@testable import PlaygroundEngine

@Suite(.serialized)
struct ConversionLearningTests {
  private func directory() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func texts(_ engine: PlaygroundEngine, _ reading: String, boundaries: [Int] = []) throws -> [String] {
    let data = try JSONSerialization.data(withJSONObject: ["reading": reading, "expanded": true, "boundaries": boundaries])
    let result = try engine.convert(String(decoding: data, as: UTF8.self))
    let object = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    return try #require(object["candidates"] as? [[String: Any]]).compactMap { $0["text"] as? String }
  }

  @Test func confirmedChoicePersistsWithoutOverridingOtherContextAndResetRestoresBaseline() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try PlaygroundEngine(learningDirectory: folder)
    let before = try texts(engine, "あめ")
    #expect(before.contains("飴"))
    for _ in 0..<3 { #expect(try engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":2}"#)) }
    let learned = try texts(engine, "あめ")
    #expect(learned.first == "飴")
    #expect(Set(before).isSubset(of: Set(learned)))
    #expect(try texts(engine, "あめがふる").first == "雨が降る")
    let restarted = try PlaygroundEngine(learningDirectory: folder)
    #expect(try texts(restarted, "あめ").first == "飴")
    try restarted.resetLearning()
    #expect(try texts(restarted, "あめ") == before)
    let cleanRestart = try PlaygroundEngine(learningDirectory: folder)
    #expect(try texts(cleanRestart, "あめ") == before)
  }

  @Test func unconfirmedUnknownAndInvalidSelectionsDoNotLearn() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try PlaygroundEngine(learningDirectory: folder)
    #expect(try !engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":2}"#))
    let before = try texts(engine, "あめ")
    #expect(try !engine.learn(#"{"reading":"あめ","text":"偽","start":0,"end":2}"#))
    #expect(try !engine.learn(#"{"reading":"あめ","text":"飴","start":-1,"end":2}"#))
    #expect(try !engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":1}"#))
    #expect(try texts(PlaygroundEngine(learningDirectory: folder), "あめ") == before)
    try engine.resetLearning()
    #expect(try !engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":2}"#))
  }

  @Test func sectionLearningRecordsOnlyConfirmedUnits() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try PlaygroundEngine(learningDirectory: folder)
    let choices = try texts(engine, "あめを", boundaries: [2])
    #expect(choices.contains("飴を"))
    for _ in 0..<3 { #expect(try engine.learn(#"{"reading":"あめを","text":"飴","start":0,"end":2}"#)) }
    #expect(try texts(engine, "あめ").first == "飴")
    let after = try texts(engine, "あめを", boundaries: [2])
    #expect(try engine.learn(#"{"reading":"あめを","text":"雨","start":0,"end":2}"#))
    #expect(try texts(engine, "あめを", boundaries: [2]).first == "雨を")
    let restarted = try PlaygroundEngine(learningDirectory: folder)
    #expect(try texts(restarted, "あめを", boundaries: [2]).first == "雨を")
    #expect(Set(choices).isSubset(of: Set(after)))
  }

  @Test func learningKeepsTheFullBoundaryCandidatePool() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try PlaygroundEngine(learningDirectory: folder)
    let before = try texts(engine, "はしでたべました", boundaries: [1])
    #expect(before.count > 100)
    let chosen = try #require(before.last)
    let data = try JSONSerialization.data(withJSONObject: ["reading": "はしでたべました", "text": chosen, "start": 0, "end": 8])
    #expect(try engine.learn(String(decoding: data, as: UTF8.self)))
    let after = try texts(engine, "はしでたべました", boundaries: [1])
    #expect(after.count >= before.count)
    #expect(after.first == chosen)
  }

  @Test func emptyLearningMatchesUnpersonalizedCorpus() throws {
    struct Fixture: Decodable { let reading: String }
    let fixtures = try JSONDecoder().decode([Fixture].self, from: PlaygroundEngine.fixtures())
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let enabled = try PlaygroundEngine(learningDirectory: folder)
    let baseline = try PlaygroundEngine()
    for fixture in fixtures {
      #expect(try texts(enabled, fixture.reading) == texts(baseline, fixture.reading))
    }
  }

  @Test func damagedPreferenceCacheRecoversAndCanLearnAgain() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("{broken".utf8).write(to: folder.appendingPathComponent("confirmed.json"))
    let engine = try PlaygroundEngine(learningDirectory: folder)
    #expect(try texts(engine, "あめ").contains("飴"))
    #expect(try engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":2}"#))
    let restarted = try PlaygroundEngine(learningDirectory: folder)
    #expect(try texts(restarted, "あめ").first == "飴")
    try restarted.resetLearning()
  }

  @Test func unpersonalizedBenchmarksStayUnchanged() throws {
    let engine = try PlaygroundEngine()
    let before = try texts(engine, "あめ")
    #expect(try !engine.learn(#"{"reading":"あめ","text":"飴","start":0,"end":2}"#))
    try engine.resetLearning()
    #expect(try texts(engine, "あめ") == before)
  }

  #if os(macOS)
  @Test func failedResetStillClearsInMemoryPreferencesAndCandidatePools() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try PlaygroundEngine(learningDirectory: folder)
    _ = try texts(engine, "あめ")
    let selection = ConfirmedConversion(reading: "あめ", text: "飴", start: 0, end: 2)
    let candidate = try #require(engine.learning.candidate(for: selection))
    let rain = try #require(engine.learning.candidate(for: ConfirmedConversion(reading: "あめ", text: "雨", start: 0, end: 2)))
    try engine.learning.confirm(selection)
    #expect(engine.learning.ranked([rain, candidate], reading: "あめ").first?.text == "飴")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
    #expect(throws: (any Error).self) { try engine.resetLearning() }
    #expect(engine.learning.candidate(for: selection) == nil)
    #expect(engine.learning.ranked([rain, candidate], reading: "あめ").first?.text == "雨")
    // The cache must remain usable after permissions are restored and reset is retried.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    try engine.resetLearning()
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("confirmed.json").path))
    #expect(try texts(engine, "あめ").contains("雨"))
  }
  #endif
}
