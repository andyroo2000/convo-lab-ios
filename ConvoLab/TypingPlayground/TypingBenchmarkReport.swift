import Foundation
import PlaygroundEngine
import UIKit

struct TypingBenchmarkFixture: Codable {
  let reading: String
  let expected: [String]
  let nativeTopChoice: String?
}

struct TypingBenchmarkSample: Codable {
  let phase: String
  let trial: Int
  let reading: String
  let boundaries: [Int]
  let wallMs: Double
  let engineMs: Double
  let candidates: [String]
  let expected: [String]
  let nativeTopChoice: String?
  let thermalState: String
}

struct TypingBenchmarkReport: Codable {
  let createdAt: Date
  let device: String
  let systemVersion: String
  let appVersion: String
  let build: String
  let backend: String
  let modelSHA256: String
  let timingScope: String
  let preloadMs: Double
  var samples: [TypingBenchmarkSample] = []
  var completed = false
  var failure: String?

  @MainActor init(preloadMs: Double) {
    createdAt = Date()
    var info = utsname()
    uname(&info)
    device = withUnsafeBytes(of: &info.machine) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    systemVersion = UIDevice.current.systemVersion
    appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    #if targetEnvironment(simulator)
      backend = "iOS simulator CPU; host Mac timing, not iPhone timing"
    #else
      backend = "Native Metal, normal effort (inference limit 1)"
    #endif
    modelSHA256 = "501f605d088f5b988791a00ae19ed46985ed7c48144f364b2f3f1f951c9b2083"
    timingScope =
      "Native actor request including JSON encoding/decoding; excludes keyboard, WebView bridge and painting. Three 24-phrase passes plus four full 160-candidate boundary requests."
    self.preloadMs = preloadMs
  }

  var ordinaryMedian: Double? {
    Self.median(samples.filter { $0.phase == "ordinary" }.map(\.wallMs))
  }

  static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  func save() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TypingBenchmarks", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("typing-benchmark.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: url, options: .atomic)
    return url
  }
}
