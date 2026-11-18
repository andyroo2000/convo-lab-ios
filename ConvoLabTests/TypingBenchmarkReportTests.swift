import XCTest

@testable import ConvoLab

@MainActor
final class TypingBenchmarkReportTests: XCTestCase {
  func testPercentilesUseNearestRankAndHandleEmptySamples() {
    XCTAssertNil(TypingBenchmarkReport.percentile([], fraction: 0.95))
    XCTAssertEqual(TypingBenchmarkReport.median([9, 1, 5, 3]), 4)
    XCTAssertEqual(TypingBenchmarkReport.median([1, 3, 9]), 3)
    XCTAssertEqual(TypingBenchmarkReport.percentile([9, 1, 5, 3], fraction: 0.5), 3)
    XCTAssertEqual(
      TypingBenchmarkReport.percentile(Array(1...20).map(Double.init), fraction: 0.95), 19)
  }

  @MainActor func testReportExportsOnlyExplicitFixtureSamples() throws {
    var report = TypingBenchmarkReport(preloadMs: 12)
    report.completed = false
    report.failure = "Cancelled; partial run"
    let url = try report.save()
    defer { try? FileManager.default.removeItem(at: url) }
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(json["completed"] as? Bool, false)
    XCTAssertEqual((json["samples"] as? [Any])?.count, 0)
    XCTAssertEqual(
      json["modelSHA256"] as? String,
      "501f605d088f5b988791a00ae19ed46985ed7c48144f364b2f3f1f951c9b2083")
    XCTAssertNil(json["notebook"])
  }
}
