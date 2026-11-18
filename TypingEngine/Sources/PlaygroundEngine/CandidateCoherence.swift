import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

private struct ReadingUnit {
  let word: String
  let ruby: String
  let start: Int
  var end: Int { start + ruby.count }
}

private func readingUnits(_ candidate: Candidate) -> [ReadingUnit] {
  var offset = 0
  return candidate.data.map { item in
    defer { offset += item.ruby.count }
    return ReadingUnit(word: item.word, ruby: item.ruby, start: offset)
  }
}

private func matchingEdge(_ word: [Character], _ ruby: [Character]) -> Int {
  zip(word, ruby).prefix(while: { $0 == $1 }).count
}

private func preservesWord(_ original: ReadingUnit, alternatives: [ReadingUnit]) -> Bool {
  let parts = alternatives.filter { $0.start < original.end && $0.end > original.start }
  guard parts.first?.start == original.start, parts.last?.end == original.end else { return false }
  let text = parts.map(\.word).joined()
  if text == original.word { return true }
  if original.word.range(of: "^[\\p{Hiragana}]+$", options: .regularExpression) != nil {
    return false
  }
  let normalized = Array(
    original.word.applyingTransform(.hiraganaToKatakana, reverse: false) ?? original.word)
  let ruby = Array(original.ruby)
  let prefix = matchingEdge(normalized, ruby)
  let suffix = matchingEdge(Array(normalized.reversed()), Array(ruby.reversed()))
  guard text.hasPrefix(String(original.word.prefix(prefix))),
    text.hasSuffix(String(original.word.suffix(suffix)))
  else { return false }
  let coreStart = original.start + prefix
  let coreEnd = original.end - suffix
  // A conjugated word must retain a lexical unit including some okurigana:
  // 食べ + ました is valid; 多 + べ + ました is not a useful alternative.
  if suffix > 0 && !parts.contains(where: { $0.start <= coreStart && $0.end > coreEnd }) {
    return false
  }
  // Reject recombinations such as 派 + 史 for はし, while allowing literal
  // kana suffixes to have different dictionary tokenization.
  return !parts.contains { $0.start > coreStart && $0.start < coreEnd }
}

func isCoherentAlternative(_ candidate: Candidate, reference: Candidate) -> Bool {
  let alternatives = readingUnits(candidate)
  let words = readingUnits(reference).filter {
    $0.word.range(of: "[\\p{Han}\\p{Hiragana}]", options: .regularExpression) != nil
  }
  return words.allSatisfy { preservesWord($0, alternatives: alternatives) }
}
