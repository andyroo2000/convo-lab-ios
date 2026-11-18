public import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Owned exclusively by the app's serial actor. Never called on the UI thread.
public final class PlaygroundEngine {
  let converter: KanaKanjiConverter
  let boundaryConverter: BoundaryCandidateConverter
  let boundaryRanker: NeuralBoundaryRanker
  let modelURL: URL
  var options: ConvertRequestOptions
  private var recentReading: String?
  private var recentCandidates: [Candidate] = []
  public private(set) var preparationTimings: [String: Double] = [:]

  public init() throws {
    let start = ContinuousClock.now
    guard
      let modelURL = Bundle.module.url(
        forResource: "model", withExtension: "gguf")
    else { throw PlaygroundFailure.missingModel }
    let dictionary = DicdataStore.withDefaultDictionary()
    converter = KanaKanjiConverter(dicdataStore: dictionary)
    boundaryConverter = BoundaryCandidateConverter(dicdataStore: dictionary)
    let dictionaryReady = ContinuousClock.now
    self.modelURL = modelURL
    boundaryRanker = try NeuralBoundaryRanker(converter: converter, modelURL: modelURL)
    let modelReady = ContinuousClock.now
    // Learning is disabled; this intentionally nonexistent path is never written.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    options = ConvertRequestOptions(
      needTypoCorrection: false, requireJapanesePrediction: false,
      requireEnglishPrediction: false, keyboardLanguage: .ja_JP,
      learningType: .nothing, memoryDirectoryURL: scratch, sharedContainerURL: scratch,
      textReplacer: .withDefaultEmojiDictionary(),
      specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
      zenzaiMode: .on(
        weight: modelURL, inferenceLimit: 1, personalizationMode: nil,
        versionDependentMode: .v3(.init())),
      metadata: .init(versionString: "ConvoLab iPhone playground")
    )
    _ = try convert("{\"reading\":\"こんにちは\"}")
    preparationTimings = [
      "dictionaryMs": Self.milliseconds(from: start, to: dictionaryReady),
      "modelAndBoundaryWarmupMs": Self.milliseconds(from: dictionaryReady, to: modelReady),
      "ordinaryWarmupMs": Self.milliseconds(from: modelReady, to: .now),
    ]
  }

  private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: end).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }

  public func convert(_ json: String) throws -> String {
    let request = try JSONDecoder().decode(ConversionInput.self, from: Data(json.utf8))
    try request.validate()
    let start = ContinuousClock.now
    let candidates = try candidates(for: request)
    let elapsed = start.duration(to: .now).components
    let result = ConversionOutput(
      candidates: candidates,
      engineMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
      expansion: request.expanded == true ? "whole-phrase-neural-and-dictionary" : nil
    )
    return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
  }

  func candidates(for request: ConversionInput) throws -> [ConversionCandidate] {
    var composition = ComposingText()
    composition.insertAtCursorPosition(request.reading, inputStyle: .direct)
    let adjusted = request.boundaries?.isEmpty == false
    var pool = try neuralCandidates(composition, reading: request.reading, reuse: adjusted)
    if adjusted {
      pool = try boundaryCandidates(
        reading: request.reading, boundaries: request.boundaries ?? [], neural: pool,
        options: options)
    } else if request.expanded == true {
      pool += expandedCandidates(
        composition, converter: converter, options: options, reference: pool.first)
    }
    return Array(
      serializeCandidates(pool, reading: request.reading, neuralRanked: adjusted)
        .prefix(request.expanded == true ? 160 : 10))
  }

  private func neuralCandidates(_ composition: ComposingText, reading: String, reuse: Bool) throws -> [Candidate] {
    // Boundary changes do not change the whole-phrase neural proposal. Learning
    // is disabled, and this cache retains only the most recent exact reading.
    if reuse && reading == recentReading { return recentCandidates }
    converter.stopComposition()
    let results = converter.requestCandidates(composition, options: options)
    guard converter.zenzStatus == "load \(modelURL.absoluteString)"
    else { throw PlaygroundFailure.modelNotLoaded }
    recentReading = reading
    recentCandidates = results.mainResults
    return recentCandidates
  }

  public static func fixtures() throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: "fixtures", withExtension: "json")
    else { throw PlaygroundFailure.missingModel }
    return try Data(contentsOf: url)
  }
}

extension PlaygroundEngine {
  public static func attributions() -> String {
    guard
      let url = Bundle.module.url(
        forResource: "Attributions", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "Attributions could not be loaded." }
    return text
  }
}
