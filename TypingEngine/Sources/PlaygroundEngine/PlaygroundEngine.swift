public import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// Owned exclusively by the app's serial actor. Never called on the UI thread.
public final class PlaygroundEngine {
  let converter: KanaKanjiConverter
  var boundaryConverter: BoundaryCandidateConverter
  let dictionary: DicdataStore
  let learning: ConversionLearning
  private var boundaryRanker: NeuralBoundaryRanker?
  let modelURL: URL
  let options: ConvertRequestOptions
  private var recentReading: String?
  private var recentCandidates: [Candidate] = []
  public private(set) var preparationTimings: [String: Double] = [:]

  public init(learningDirectory: URL? = nil) throws {
    let start = ContinuousClock.now
    guard
      let modelURL = Bundle.module.url(
        forResource: "model", withExtension: "gguf")
    else { throw PlaygroundFailure.missingModel }
    learning = try ConversionLearning(directory: learningDirectory)
    dictionary = DicdataStore.withDefaultDictionary()
    converter = KanaKanjiConverter(dicdataStore: dictionary)
    boundaryConverter = BoundaryCandidateConverter(dicdataStore: dictionary)
    let dictionaryReady = ContinuousClock.now
    self.modelURL = modelURL
    // Benchmarks remain unpersonalized unless the caller supplies local storage.
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    options = ConvertRequestOptions(
      needTypoCorrection: false, requireJapanesePrediction: false,
      requireEnglishPrediction: false, keyboardLanguage: .ja_JP,
      learningType: learningDirectory == nil ? .nothing : .inputAndOutput,
      memoryDirectoryURL: learningDirectory ?? scratch, sharedContainerURL: learningDirectory ?? scratch,
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
      "modelAndOrdinaryWarmupMs": Self.milliseconds(from: dictionaryReady, to: .now),
    ]
  }

  private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: end).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
  }

  func boundaryRankingEngine() throws -> NeuralBoundaryRanker {
    if let boundaryRanker { return boundaryRanker }
    // The model is already loaded and warmed for ordinary typing. Allocate the
    // additional ranking buffers only when the learner adjusts a section.
    let start = ContinuousClock.now
    let ranker = try NeuralBoundaryRanker(converter: converter, modelURL: modelURL)
    boundaryRanker = ranker
    preparationTimings["boundaryWarmupMs"] = Self.milliseconds(from: start, to: .now)
    return ranker
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
    pool = learning.ranked(pool, reading: request.reading)
    learning.remember(pool, reading: request.reading)
    return Array(
      serializeCandidates(pool, reading: request.reading, neuralRanked: adjusted)
        .prefix(request.expanded == true ? 160 : 10))
  }

  private func neuralCandidates(_ composition: ComposingText, reading: String, reuse: Bool) throws -> [Candidate] {
    // Boundary changes reuse the most recent exact reading. Confirmed learning
    // and reset both invalidate this cache before the next conversion.
    if reuse && reading == recentReading { return recentCandidates }
    converter.stopComposition()
    let results = converter.requestCandidates(composition, options: options)
    guard converter.zenzStatus == "load \(modelURL.absoluteString)"
    else { throw PlaygroundFailure.modelNotLoaded }
    recentReading = reading
    recentCandidates = results.mainResults
    return recentCandidates
  }

  public func learn(_ json: String) throws -> Bool {
    let selection = try JSONDecoder().decode(ConfirmedConversion.self, from: Data(json.utf8))
    guard learning.enabled, let candidate = learning.candidate(for: selection) else { return false }
    try learning.confirm(selection)
    converter.stopComposition()
    converter.updateLearningData(candidate)
    converter.commitUpdateLearningData()
    invalidateLearningCaches()
    return true
  }

  public func resetLearning() throws {
    guard learning.enabled else { return }
    converter.resetMemory()
    try learning.clear()
    invalidateLearningCaches()
  }

  private func invalidateLearningCaches() {
    recentReading = nil
    recentCandidates = []
    converter.stopComposition()
    boundaryConverter = BoundaryCandidateConverter(dicdataStore: dictionary)
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
