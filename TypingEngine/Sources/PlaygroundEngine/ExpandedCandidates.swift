import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

extension PlaygroundEngine {

  func expandedCandidates(
    _ composition: ComposingText,
    converter: KanaKanjiConverter,
    options: ConvertRequestOptions,
    reference: Candidate?
  ) -> [Candidate] {
    var pool: [Candidate] = []

    var rich = options
    rich.zenzaiMode = .on(
      weight: modelURL,
      inferenceLimit: 1,
      requestRichCandidates: true,
      personalizationMode: nil,
      versionDependentMode: .v3(.init())
    )
    converter.stopComposition()
    pool += converter.requestCandidates(composition, options: rich).mainResults

    // Keep neural suggestions first. Supplement them with a wider, context-
    // scored dictionary beam over the ENTIRE reading, never isolated words.
    var dictionary = options
    dictionary.zenzaiMode = .off
    dictionary.N_best = 128
    dictionary.needTypoCorrection = false
    converter.stopComposition()
    let broader = converter.requestWholePhraseCandidates(composition, options: dictionary)
      .mainResults
    if let reference {
      pool += broader.filter { isCoherentAlternative($0, reference: reference) }
    }
    return pool
  }

  func serializeCandidates(_ pool: [Candidate], reading: String, neuralRanked: Bool = false)
    -> [ConversionCandidate]
  {
    var seen = Set<String>()
    let katakana = reading.applyingTransform(.hiraganaToKatakana, reverse: false)
    return pool.compactMap { candidate in
      guard candidate.data.map(\.ruby).joined() == katakana,
        seen.insert(candidate.text).inserted
      else { return nil }
      return ConversionCandidate(
        text: candidate.text,
        reading: reading,
        sections: sections(of: candidate, reading: reading),
        units: units(of: candidate, reading: reading),
        neuralScore: neuralRanked ? Float(candidate.value) : nil
      )
    }
  }
}
