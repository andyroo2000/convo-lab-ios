import Foundation
import PlaygroundEngine

actor TypingEngineActor {
  private var engine: PlaygroundEngine?

  func prepare() throws -> Double {
    let start = ContinuousClock.now
    if engine == nil { engine = try PlaygroundEngine() }
    return Self.milliseconds(since: start)
  }

  func convert(_ input: String) throws -> String {
    guard let engine else { throw PlaygroundFailure.modelNotLoaded }
    return try engine.convert(input)
  }

  static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }
}
