public import Foundation

struct ConversionInput: Decodable {
  let reading: String
  let expanded: Bool?
  let boundaries: [Int]?

  func validate() throws {
    guard (1...120).contains(reading.count),
      !reading.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw PlaygroundFailure.invalidReading }
    var offsets = Set<Int>()
    var offset = 0
    for character in reading {
      offsets.insert(offset)
      offset += String(character).utf16.count
    }
    var previous = 0
    for boundary in boundaries ?? [] {
      guard boundary > previous, offsets.contains(boundary)
      else { throw PlaygroundFailure.invalidBoundary }
      previous = boundary
    }
  }
}

struct ConversionCandidate: Encodable {
  let text: String
  let reading: String
  let sections: [ConversionSection]
  let units: [ConversionSection]
  var neuralScore: Float? = nil
}

struct ConversionOutput: Encodable {
  let candidates: [ConversionCandidate]
  let engineMs: Double
  let expansion: String?
}

public enum PlaygroundFailure: Error, LocalizedError {
  case missingModel, modelNotLoaded, invalidReading, invalidBoundary
  public var errorDescription: String? {
    switch self {
    case .missingModel: "The bundled typing model is missing."
    case .modelNotLoaded: "The neural model could not start. No dictionary fallback was used."
    case .invalidReading: "Convert one line of 1–120 characters at a time."
    case .invalidBoundary: "Choose a boundary between reading characters."
    }
  }
}
