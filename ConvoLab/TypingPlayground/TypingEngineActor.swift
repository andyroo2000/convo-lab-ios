import Foundation
import PlaygroundEngine

actor TypingEngineActor {
  private var engine: PlaygroundEngine?
  private let learnsConversions: Bool

  init(learnsConversions: Bool = false) { self.learnsConversions = learnsConversions }

  private var learningDirectory: URL? {
    guard learnsConversions else { return nil }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("JournalKeyboardLearning", isDirectory: true)
  }

  func learn(_ selection: String) throws -> Bool {
    guard let engine else { return false }
    return try engine.learn(selection)
  }

  func resetLearning() throws {
    if let engine { try engine.resetLearning() }
    else if let directory = learningDirectory, FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }


  func prepare() throws -> Double {
    let start = ContinuousClock.now
    if engine == nil { engine = try PlaygroundEngine(learningDirectory: learningDirectory) }
    return Self.milliseconds(since: start)
  }

  func convert(_ input: String) throws -> String {
    guard let engine else { throw PlaygroundFailure.modelNotLoaded }
    return try engine.convert(input)
  }

  func preparationTimings() -> [String: Double] { engine?.preparationTimings ?? [:] }

  static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }
}
