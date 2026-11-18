import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

extension PlaygroundEngine {

  func boundaryCandidates(
    reading: String, boundaries: [Int], neural: [Candidate], options: ConvertRequestOptions
  ) throws -> [Candidate] {
    // Include only sentences whose dictionary units respect every requested cut.
    let compatible = neural.filter { candidate in
      var offset = 0
      let edges = Set(
        candidate.data.map { unit in
          offset += unit.ruby.utf16.count
          return offset
        })
      return boundaries.allSatisfy { edges.contains($0) }
    }
    let pool =
      compatible
      + boundaryConverter.candidates(
        reading: reading, boundaries: boundaries, options: options
      )

    return try boundaryRanker.rank(pool, reading: reading)

  }
}
