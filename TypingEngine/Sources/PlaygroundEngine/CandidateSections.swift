import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct ConversionSection: Encodable {
  let text: String
  let reading: String
}

// Use the engine's own clause boundaries, not a separate per-word conversion.
func sections(of candidate: Candidate, reading: String) -> [ConversionSection] {
  var remaining = candidate.data[...]
  var source = reading[...]
  var result: [ConversionSection] = []
  while !remaining.isEmpty {
    let clause = Candidate.makePrefixClauseCandidate(data: remaining)
    guard !clause.data.isEmpty else { return [] }
    let count = clause.data.reduce(0) { $0 + $1.ruby.count }
    result.append(ConversionSection(text: clause.text, reading: String(source.prefix(count))))
    source = source.dropFirst(count)
    remaining = remaining.dropFirst(clause.data.count)
  }
  // Template candidates may not match their dictionary data. Fall back safely.
  return source.isEmpty && result.map(\.text).joined() == candidate.text ? result : []
}

func units(of candidate: Candidate, reading: String) -> [ConversionSection] {
  var source = reading[...]
  return candidate.data.map { item in
    let part = String(source.prefix(item.ruby.count))
    source = source.dropFirst(item.ruby.count)
    return ConversionSection(text: item.word, reading: part)
  }
}
