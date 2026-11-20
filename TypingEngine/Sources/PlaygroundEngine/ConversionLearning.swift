import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct ConfirmedConversion: Codable {
  let reading: String
  let text: String
  let start: Int
  let end: Int
}

/// Only engine-backed, explicitly confirmed words can enter local learning.
/// Keep a small result window so an expanded response cannot invalidate a tap.
final class ConversionLearning {
  let enabled: Bool
  private var readings: [String] = []
  private var pools: [String: [Candidate]] = [:]
  private let preferenceURL: URL?
  private var preferences: [ConfirmedConversion] = []

  init(directory: URL?) throws {
    enabled = directory != nil
    preferenceURL = directory?.appendingPathComponent("confirmed.json")
    if let directory {
      try LearningStorage.prepare(directory)
      if let url = preferenceURL, FileManager.default.fileExists(atPath: url.path) {
        let data = try Data(contentsOf: url)
        // A damaged preference cache must not prevent the keyboard from starting.
        let restored = (try? JSONDecoder().decode([ConfirmedConversion].self, from: data)) ?? []
        preferences = Array(restored.suffix(256))
      }
    }
  }

  func remember(_ pool: [Candidate], reading: String) {
    guard enabled else { return }
    readings.removeAll { $0 == reading }
    readings.append(reading)
    var seen = Set<String>()
    let kana = reading.applyingTransform(.hiraganaToKatakana, reverse: false)
    let valid = (pool + (pools[reading] ?? [])).filter {
      $0.data.map(\.ruby).joined() == kana && seen.insert($0.text).inserted
    }
    // Retain two complete 160-choice responses, not every prior boundary query.
    pools[reading] = Array(valid.prefix(320))
    if readings.count > 8 { pools.removeValue(forKey: readings.removeFirst()) }
  }

  func clear() throws {
    defer { preferences = []; readings = []; pools = [:] }
    if let preferenceURL, FileManager.default.fileExists(atPath: preferenceURL.path) {
      try FileManager.default.removeItem(at: preferenceURL)
    }
  }

  func protectStorage() throws {
    if let preferenceURL { try LearningStorage.protect(preferenceURL.deletingLastPathComponent()) }
  }

  func confirm(_ selection: ConfirmedConversion) throws {
    guard let preferenceURL else { return }
    var next = preferences.filter {
      $0.reading != selection.reading || $0.start != selection.start || $0.end != selection.end
    }
    next.append(selection)
    next = Array(next.suffix(256))
    try JSONEncoder().encode(next).write(to: preferenceURL, options: .atomic)
    try protectStorage()
    preferences = next
  }

  // An explicit choice for this exact phrase also survives boundary reranking.
  // Different phrase contexts still use the unchanged neural/dictionary scores.
  func ranked(_ pool: [Candidate], reading: String) -> [Candidate] {
    let relevant = preferences.filter { $0.reading == reading }
    guard !relevant.isEmpty else { return pool }
    let scored: [(index: Int, candidate: Candidate, matches: Int)] = pool.enumerated().map { index, candidate in
      (index, candidate, relevant.filter { slice(candidate, selection: $0) != nil }.count)
    }
    let sorted = scored.sorted { left, right in
      left.matches == right.matches ? left.index < right.index : left.matches > right.matches
    }
    return sorted.map(\.candidate)
  }

  func candidate(for selection: ConfirmedConversion) -> Candidate? {
    guard selection.start >= 0, selection.end > selection.start,
      selection.end <= selection.reading.utf16.count else { return nil }
    for candidate in pools[selection.reading] ?? [] {
      if let chosen = slice(candidate, selection: selection) { return chosen }
    }
    return nil
  }

  private func slice(_ candidate: Candidate, selection: ConfirmedConversion) -> Candidate? {
    guard candidate.isLearningTarget,
      candidate.data.map(\.ruby).joined() == selection.reading.applyingTransform(.hiraganaToKatakana, reverse: false)
    else { return nil }
    var offset = 0
    var selected: [DicdataElement] = []
    for unit in candidate.data {
      let end = offset + unit.ruby.utf16.count
      defer { offset = end }
      if offset >= selection.start && end <= selection.end { selected.append(unit) }
    }
    let count = selected.map(\.ruby).joined().utf16.count
    guard count == selection.end - selection.start,
      selected.map(\.word).joined() == selection.text,
      let last = selected.last else { return nil }
    return Candidate(text: selection.text, value: candidate.value,
      composingCount: .surfaceCount(count), lastMid: last.mid, data: selected,
      isLearningTarget: candidate.isLearningTarget)
  }
}
